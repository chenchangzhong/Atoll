/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import Network
import CryptoKit
import Darwin
import Defaults

/// Reason an upload was refused, mirroring upstream's HTTP contract.
enum LocalSendReceiveError: Equatable {
    case badRequest
    case unprocessable
    case server

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .unprocessable: return 422
        case .server: return 500
        }
    }
}

/// A `prepare-upload` that is waiting for the user's decision.
struct LocalSendIncomingRequest: Equatable, Identifiable {
    struct File: Equatable {
        let name: String
        let size: Int

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    let id = UUID()
    let senderAlias: String
    let senderIP: String
    let files: [File]
}

/// One file inside an accepted receive session.
struct LocalSendReceiveFile: Equatable, Sendable {
    let id: String
    let name: String
    let size: Int
    let sha256: String?
    let token: String
}

/// Receives files pushed by LocalSend peers.
///
/// The HTTP contract mirrors upstream LocalSend (`packages/core/src/http/server`):
/// one session slot, `prepare-upload` handing out per-file tokens, uploads only
/// from the address that prepared the session, and a checksum mismatch answered
/// with 422. Files land in the same place LocalSend itself would use, with the
/// same `name (1).ext` de-duplication.
@MainActor
final class LocalSendReceiveService: ObservableObject {
    static let shared = LocalSendReceiveService()

    private let destinationDirectory: URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }()

    // Single session slot, like upstream's `SessionStateV2`.
    private var sessionID: String?
    private var senderIP: String?
    /// Last time the transfer made progress; the reaper measures idle time from it.
    private var lastSessionActivity = Date.distantPast
    private var files: [String: LocalSendReceiveFile] = [:]

    /// How long an accepted session may go without progress before its slot is
    /// released and the notch is freed.
    private let abandonedSessionTimeout: TimeInterval = 90
    /// After a failed upload the slot is kept so the sender can retry the same
    /// file with the same token (upstream keeps it forever), but a fresh
    /// `prepare-upload` — the common "send it again" — waits for it, so this
    /// window is deliberately much shorter.
    private let failedSessionTimeout: TimeInterval = 30
    private var sessionReaperTask: Task<Void, Never>?

    @Published private(set) var receiveProgress: Double = 0
    @Published private(set) var isReceiving = false
    /// Set while a `prepare-upload` is waiting for the user's decision; the notch
    /// renders its card from this.
    @Published private(set) var pendingRequest: LocalSendIncomingRequest?
    @Published private(set) var lastReceivedNames: [String] = []
    /// Short-lived summary the notch shows once a transfer is stored.
    @Published private(set) var completionText: String?
    private var clearCompletionTask: Task<Void, Never>?
    /// Set when an upload fails. Without it the notch retracted silently while the
    /// session slot stayed claimed, and the next sender only got a 409.
    @Published private(set) var failureText: String?
    /// Files of the current session that failed and are still retryable. A failed
    /// file stays in `files` for the retry window, so it must not keep the session
    /// "receiving" once the remaining files are done.
    private var failedFileIDs: Set<String> = []
    /// The last failure message, kept so a session that ends with a mix of stored
    /// and failed files can still say what went wrong (the text is cleared while
    /// the next file uploads, so progress stays visible).
    private var lastFailureText: String?
    /// Set while an upload should stop because the user asked it to.
    private var cancelRequested = false
    /// Lets the user's cancel tear down the connections reading uploads, instead of
    /// waiting for the next chunk or the read deadline.
    private var activeUploads = ActiveUploadCancellations()
    private var userCancelled = false

    /// How long the sender waits for the user before we answer 500.
    private let decisionTimeout: TimeInterval = 60
    /// True while a `prepare` is between publishing its request and creating the
    /// session, so a second request cannot clobber the continuation.
    private var decisionInFlight = false
    private var decisionContinuation: CheckedContinuation<LocalSendReceiveDecision, Never>?
    private var decisionTimeoutTask: Task<Void, Never>?

    private init() {}

    /// Bounds concurrent *uploads*: register/info must never be refused because a
    /// peer parked upload connections.
    private static let uploadSlots = DispatchSemaphore(value: 4)
    /// A high global ceiling, kept so that flooding the port cannot spawn an
    /// unbounded number of reader tasks. High enough that an upload cannot make
    /// the server unreachable for discovery traffic.
    private static let connectionSlots = DispatchSemaphore(value: 64)

    /// Entry point used by the 53317 listener in `LocalSendService`.
    nonisolated func accept(_ connection: NWConnection) {
        guard Self.connectionSlots.wait(timeout: .now()) == .success else {
            Logger.log("LocalSend receive: refusing a connection, too many open", category: .extensions)
            connection.cancel()
            return
        }
        connection.start(queue: .global(qos: .utility))
        LocalSendHTTPConnection(connection: connection) {
            Self.connectionSlots.signal()
        }.start()
    }

    // MARK: - Session lifecycle

    /// Outcome of a `prepare-upload`, mapped to the HTTP contract by the caller.
    enum PrepareOutcome {
        case busy
        case cancelled
        case emptyFiles
        case accepted(sessionID: String, tokens: [String: String])
        case declined
        case timedOut
    }

    /// Runs the decision for a `prepare-upload`, then creates the session.
    ///
    /// The default is to ask: the request is published for the notch card and the
    /// caller awaits the user (or the auto-accept default, or the timeout).
    func prepare(
        files incoming: [(id: String, name: String, size: Int, sha256: String?)],
        senderAlias: String,
        senderIP: String
    ) async -> PrepareOutcome {
        // Upstream answers 400 "No files provided" before it looks at sessions.
        guard !incoming.isEmpty else { return .emptyFiles }
        guard sessionID == nil, pendingRequest == nil, !decisionInFlight else { return .busy }

        completionText = nil
        clearCompletionTask?.cancel()

        let request = LocalSendIncomingRequest(
            senderAlias: senderAlias.isEmpty ? senderIP : senderAlias,
            senderIP: senderIP,
            files: incoming.map { LocalSendIncomingRequest.File(name: $0.name, size: $0.size) }
        )

        if !Defaults[.localSendAutoAcceptIncoming] {
            decisionInFlight = true
            let decision = await awaitDecision(for: request)
            decisionInFlight = false
            switch decision {
            case .declined: return .declined
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .accepted: break
            }
        }

        return beginSession(files: incoming, senderIP: senderIP)
    }

    private enum LocalSendReceiveDecision {
        case accepted
        case declined
        case cancelled
        case timedOut
    }

    private func awaitDecision(for request: LocalSendIncomingRequest) async -> LocalSendReceiveDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<LocalSendReceiveDecision, Never>) in
            decisionContinuation = continuation
            pendingRequest = request
            decisionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.decisionTimeout ?? 60) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.resolveDecision(.timedOut) }
            }
        }
    }

    /// Called by the notch card (and by the timeout).
    private func resolveDecision(_ decision: LocalSendReceiveDecision) {
        decisionTimeoutTask?.cancel()
        decisionTimeoutTask = nil
        pendingRequest = nil
        let continuation = decisionContinuation
        decisionContinuation = nil
        continuation?.resume(returning: decision)
    }

    /// Notch card actions.
    func acceptPendingRequest() { resolveDecision(.accepted) }
    func declinePendingRequest() { resolveDecision(.declined) }

    /// Creates a session for an accepted `prepare-upload`.
    private func beginSession(
        files incoming: [(id: String, name: String, size: Int, sha256: String?)],
        senderIP: String
    ) -> PrepareOutcome {
        let id = UUID().uuidString
        var tokens: [String: String] = [:]
        var accepted: [String: LocalSendReceiveFile] = [:]
        for file in incoming {
            let token = UUID().uuidString
            tokens[file.id] = token
            accepted[file.id] = LocalSendReceiveFile(
                id: file.id,
                name: file.name,
                size: file.size,
                sha256: file.sha256,
                token: token
            )
        }

        sessionID = id
        self.senderIP = senderIP
        failedFileIDs = []
        lastFailureText = nil
        lastSessionActivity = Date()
        files = accepted
        receiveProgress = 0
        isReceiving = true
        lastReceivedNames = []
        armSessionReaper()
        Logger.log("LocalSend receive: session \(id) prepared for \(accepted.count) file(s) from \(senderIP)", category: .extensions)
        return .accepted(sessionID: id, tokens: tokens)
    }

    /// Releases the session slot and the notch once the transfer has been idle for
    /// the given timeout (default: an abandoned session) — the sender walked away,
    /// or the request was accepted and no upload ever started. Progress keeps it
    /// alive, so a slow multi-minute upload is not cut off mid-file (a plain
    /// per-session deadline used to do exactly that).
    private func armSessionReaper(after timeout: TimeInterval? = nil) {
        sessionReaperTask?.cancel()
        let armed = sessionID
        let idleTimeout = timeout ?? abandonedSessionTimeout
        sessionReaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let idle = await MainActor.run { Date().timeIntervalSince(self.lastSessionActivity) }
                guard idle >= idleTimeout else { continue }
                await MainActor.run {
                    // Re-check inside the block: a new upload can have refreshed
                    // the timestamp between the measurement and this hop.
                    guard self.sessionID == armed,
                          Date().timeIntervalSince(self.lastSessionActivity) >= idleTimeout
                    else { return }
                    Logger.log("LocalSend receive: session \(armed ?? "?") idle; releasing the slot", category: .extensions)
                    self.releaseSession()
                }
                return
            }
        }
    }

    /// Clears the single session slot and everything the notch derives from it.
    private func releaseSession() {
        failureText = nil
        lastFailureText = nil
        failedFileIDs = []
        sessionID = nil
        senderIP = nil
        files = [:]
        isReceiving = false
        receiveProgress = 0
        lastReceivedNames = []
    }

    /// Records a failed upload: what the notch shows, and why the session is still
    /// claimed (upstream lets the sender retry the same file, so the slot is kept
    /// until the reaper or an explicit release).
    func noteUploadFailure(_ error: LocalSendReceiveError, file: LocalSendReceiveFile) {
        let fileName = file.name
        failedFileIDs.insert(file.id)
        // One failure path (a destination that cannot be written) returned without
        // clearing this, which left the progress card up forever and the failure
        // card invisible behind it.
        isReceiving = ReceiveSessionPolicy.isReceiving(fileIDs: Set(files.keys), failedFileIDs: failedFileIDs)
        guard ReceiveSessionPolicy.recordsFailureCard(userCancelled: userCancelled) else {
            // The abort is what the user asked for; no failure card for it.
            userCancelled = false
            cancelRequested = false
            return
        }
        let reason: String
        switch error {
        case .unprocessable:
            reason = NSLocalizedString("Checksum mismatch", comment: "LocalSend: the received file does not match its hash")
        case .badRequest:
            reason = NSLocalizedString("Larger than announced", comment: "LocalSend: the upload exceeded the size it declared")
        default:
            reason = NSLocalizedString("Transfer interrupted", comment: "LocalSend: the upload failed")
        }
        failureText = String(
            format: NSLocalizedString("Could not receive %@: %@", comment: "LocalSend: failure card title"),
            fileName,
            reason
        )
        lastFailureText = failureText
        armSessionReaper(after: failedSessionTimeout)
        // Deliberately not auto-cleared: the session slot is still claimed, and the
        // Release action is the way out (including for an automatically accepted
        // transfer whose notch never opened). The text goes away when the session
        // is released, when the user releases it, or when the next upload starts.
    }

    /// The user cancelled an in-flight transfer from the notch: the streaming loop
    /// stops, its temporary file is removed, the session is released and no failure
    /// card is shown for the abort the user asked for.
    func cancelActiveTransfer() {
        // Only meaningful while something is actually being received; without this
        // a cancel that arrives when nothing is running left the sticky
        // `userCancelled` set for the next transfer.
        guard ReceiveSessionPolicy.canCancel(isReceiving: isReceiving, hasSession: sessionID != nil) else { return }
        Logger.log("LocalSend receive: cancelled by the user", category: .extensions)
        cancelRequested = true
        userCancelled = true
        activeUploads.cancelAll()
        isReceiving = false
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
        releaseSession()
    }

    /// Registered by the upload connection so a user cancel can end the read now.
    func registerActiveUploadCancellation(fileID: String, cancel: @escaping () -> Void) {
        activeUploads.register(fileID: fileID, cancel: cancel)
    }

    func clearActiveUploadCancellation(fileID: String) {
        activeUploads.clear(fileID: fileID)
    }

    /// The user released a failed transfer instead of waiting for the reaper.
    func discardFailedTransfer() {
        failureText = nil
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
        releaseSession()
        Logger.log("LocalSend receive: failed transfer released by the user", category: .extensions)
    }

    /// The sender walked away while we were still waiting for the user.
    ///
    /// A v2 sender cannot send `/cancel` before it knows the session id — that is
    /// only known once `prepare-upload` answers — so an abandoned request shows up
    /// as the connection closing. Without this the card kept asking, the slot
    /// stayed claimed, and clicking Accept created a session nobody would ever
    /// upload to.
    func abandonPendingRequest(senderIP: String) {
        guard let pending = pendingRequest, pending.senderIP == senderIP else { return }
        Logger.log("LocalSend receive: sender left while the decision was pending", category: .extensions)
        resolveDecision(.cancelled)
    }

    /// An accepted session whose sender is already gone: the `200` could not be
    /// delivered, so there is nothing to wait for.
    func abandonUnreachableSession(sessionID: String) {
        guard self.sessionID == sessionID else { return }
        Logger.log("LocalSend receive: sender was gone before the accepted session started", category: .extensions)
        sessionReaperTask?.cancel()
        sessionReaperTask = nil
        releaseSession()
    }

    /// The sender ended the transfer (`POST /api/localsend/v2/cancel`).
    func cancelTransfer(sessionID requested: String?, senderIP: String) {
        if let pending = pendingRequest, pending.senderIP == senderIP {
            // Upstream answers 403 "Cancelled by sender" here, not a timeout.
            resolveDecision(.cancelled)
        }
        if let activeSession = sessionID, self.senderIP == senderIP,
           requested == nil || requested == activeSession {
            Logger.log("LocalSend receive: sender cancelled session \(activeSession)", category: .extensions)
            sessionReaperTask?.cancel()
            sessionReaperTask = nil
            releaseSession()
        }
    }

    /// Validates an upload against the active session; nil means 403.
    func authorizeUpload(sessionID requested: String, fileID: String, token: String, senderIP: String) -> LocalSendReceiveFile? {
        guard let activeSession = sessionID, let activeIP = self.senderIP,
              activeSession == requested, activeIP == senderIP
        else { return nil }
        guard let file = files[fileID], file.token == token else { return nil }
        return file
    }

    /// Streams one upload to disk, hashing on the way, and stores it on success.
    nonisolated func receiveUpload(file: LocalSendReceiveFile, body: any LocalSendHTTPBody) async -> LocalSendReceiveError? {
        await MainActor.run {
            self.isReceiving = true
            self.cancelRequested = false
            // A cancel that arrived after the previous transfer finished must not
            // suppress this one's failure card (or shorten its slot window).
            self.userCancelled = false
            self.failureText = nil
            self.receiveProgress = 0
            self.lastSessionActivity = Date()
            self.armSessionReaper()
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-localsend-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            await MainActor.run { self.isReceiving = false }
            Logger.log("LocalSend receive: cannot create a temporary file for \(file.name)", category: .extensions)
            return .server
        }

        var hasher = SHA256()
        var written = 0
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            while let chunk = try await body.nextChunk() {
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += chunk.count
                let fraction = file.size > 0 ? min(1, Double(written) / Double(file.size)) : 0
                let cancelled = await MainActor.run { () -> Bool in
                    self.receiveProgress = fraction
                    // Any byte counts as progress, including for a stream that
                    // announced no size.
                    self.lastSessionActivity = Date()
                    return self.cancelRequested
                }
                if cancelled { throw LocalSendProtocolError.cancelled }
            }
        } catch LocalSendProtocolError.tooLarge {
            try? FileManager.default.removeItem(at: temporary)
            await MainActor.run { self.isReceiving = false }
            Logger.log("LocalSend receive: \(file.name) exceeded the declared size", category: .extensions)
            return .badRequest
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            await MainActor.run { self.isReceiving = false }
            Logger.log("LocalSend receive: upload of \(file.name) aborted: \(error.localizedDescription)", category: .extensions)
            return .server
        }

        if file.size > 0, written != file.size {
            try? FileManager.default.removeItem(at: temporary)
            await MainActor.run { self.isReceiving = false }
            Logger.log("LocalSend receive: \(file.name) truncated (\(written) of \(file.size) bytes)", category: .extensions)
            return .server
        }

        if let expected = file.sha256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: temporary)
                await MainActor.run { self.isReceiving = false }
                Logger.log("LocalSend receive: checksum mismatch for \(file.name)", category: .extensions)
                return .unprocessable
            }
        }

        let stored: URL? = await MainActor.run {
            let destination = self.uniqueDestination(for: file.name)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                Logger.log("LocalSend receive: cannot store \(file.name): \(error.localizedDescription)", category: .extensions)
                return nil
            }
            // A successful store clears any earlier failure for this file, so
            // "failed" never means "failed at some point".
            self.failedFileIDs.remove(file.id)
            self.files[file.id] = nil
            // Append before composing the summary: reading the list first made a
            // single-file transfer report "Stored 0 files in Downloads".
            self.lastReceivedNames.append(destination.lastPathComponent)
            let names = self.lastReceivedNames
            if self.files.isEmpty {
                self.sessionID = nil
                self.senderIP = nil
                self.completionText = names.count == 1
                    ? String(format: NSLocalizedString("Stored %@ in Downloads", comment: "LocalSend: a received file was stored"), names[0])
                    : String(format: NSLocalizedString("Stored %lld files in Downloads", comment: "LocalSend: several received files were stored"), names.count)
                self.clearCompletionTask?.cancel()
                self.clearCompletionTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.completionText = nil }
                }
            }
            // Still receiving only while a file that has not failed is left: a
            // failed file stays in the session for its retry window, and counting
            // it would keep the progress card up with nothing to receive.
            self.isReceiving = ReceiveSessionPolicy.isReceiving(
                fileIDs: Set(self.files.keys),
                failedFileIDs: self.failedFileIDs
            )
            if self.files.isEmpty {
                self.sessionReaperTask?.cancel()
                self.sessionReaperTask = nil
            } else if self.isReceiving {
                self.armSessionReaper()
            } else if ReceiveSessionPolicy.onlyFailuresRemain(
                fileIDs: Set(self.files.keys), failedFileIDs: self.failedFileIDs
            ) {
                // Nothing is left to receive, but failed files keep their retry
                // window (ADR-0001 decision 4), so the slot is not released here.
                // What the user needs is the failure itself: the text was cleared
                // while the last file uploaded, so put it back.
                self.failureText = self.lastFailureText
                self.armSessionReaper(after: self.failedSessionTimeout)
            }
            self.receiveProgress = 0
            self.lastSessionActivity = Date()
            return destination
        }

        guard let stored else {
            try? FileManager.default.removeItem(at: temporary)
            await MainActor.run { self.isReceiving = false }
            return .server
        }
        Logger.log("LocalSend receive: stored \(stored.lastPathComponent) (\(written) bytes)", category: .extensions)
        return nil
    }

    // MARK: - Destination naming

    /// `file (1).txt`, the same shape LocalSend uses, and never a path.
    private func uniqueDestination(for rawName: String) -> URL {
        let name = LocalSendProtocol.sanitizedFileName(rawName)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = destinationDirectory.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = destinationDirectory.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }


    nonisolated static func acquireUploadSlot() -> Bool {
        uploadSlots.wait(timeout: .now()) == .success
    }

    nonisolated static func releaseUploadSlot() {
        uploadSlots.signal()
    }

    /// The peer's address as the transport reports it. Compared verbatim against
    /// the address that prepared the session, so IPv6 peers stay bound too
    /// (returning nil for anything but dotted-quad used to make the check
    /// vacuous).
    nonisolated static func hostString(from endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let value = host.debugDescription.replacingOccurrences(of: "\"", with: "")
        return value.isEmpty ? nil : value
    }
}

// MARK: - HTTP plumbing

/// Reads a request body in chunks; uploads never sit in memory as a whole.
protocol LocalSendHTTPBody: Sendable {
    /// Next chunk, or nil once the promised length has been delivered.
    func nextChunk() async throws -> Data?
}

/// One inbound TCP connection on 53317.
///
/// Deliberately off the main actor: an upload can be gigabytes and streams
/// straight to disk while hashing.
final class LocalSendHTTPConnection: @unchecked Sendable {
    private static let maximumHeadSize = 64 * 1024
    private static let maximumSmallBodySize = 4 * 1024 * 1024
    private static let maximumPrepareBodySize = 2 * 1024 * 1024
    private static let maximumUploadSize = 8 * 1024 * 1024 * 1024

    private let connection: NWConnection
    private var buffered = Data()
    /// Guards the two fields every task touches; the connection is torn down from
    /// the read path, from the watchdog and from the owning task.
    private let stateLock = NSLock()
    private var closedFlag = false
    private var receivedBytes = 0

    private let onFinish: (() -> Void)?

    init(connection: NWConnection, onFinish: (() -> Void)? = nil) {
        self.connection = connection
        self.onFinish = onFinish
    }

    /// A peer can hold a task (and an upload slot) by trickling one byte every
    /// 19 s, because the per-read deadline is satisfied by each trickle. The guard
    /// is therefore a *throughput floor* with a grace period, not a wall-clock
    /// budget: a slow but real transfer is never cut off, while a connection that
    /// has delivered almost nothing after two minutes is closed. (A 30-minute
    /// wall-clock cap used to do the latter and cut off an 8 GiB upload on a slow
    /// link.)
    /// How long a single read may stay silent before the transfer is declared
    /// dead. A sender that is really pushing a file delivers something every few
    /// hundred milliseconds; 30 s of silence means it is gone (measured: a phone
    /// whose network dropped kept quiet, and the phone itself reported an error
    /// immediately while this side still showed progress). TCP cannot tell us any
    /// sooner — a dropped network sends nothing, so there is no FIN to react to.
    /// How long a single read may stay silent before the transfer is declared
    /// dead (measured while bringing this up: a phone whose network dropped went
    /// completely silent, and the phone itself reported the error immediately
    /// while this side still showed progress; 3 s was used during bring-up for
    /// fast feedback, which is too eager for a sender that merely pauses).
    private static let readDeadline: TimeInterval = 30
    private static let progressTick: TimeInterval = 15
    private static let progressGrace: TimeInterval = 120
    private static let minimumBytesPerSecond: Double = 256

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closedFlag
    }

    private var receivedByteCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return receivedBytes
    }

    private func markClosed() {
        stateLock.lock(); closedFlag = true; stateLock.unlock()
    }

    private func noteReceived(_ count: Int) {
        stateLock.lock(); receivedBytes += count; stateLock.unlock()
    }

    func start() {
        let started = Date()
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.progressTick * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                guard elapsed > Self.progressGrace else { continue }
                let received = self.receivedByteCount
                guard Double(received) < Self.minimumBytesPerSecond * elapsed else { continue }
                Logger.log(
                    "LocalSend receive: closing a connection that delivered \(received) bytes in \(Int(elapsed))s",
                    category: .extensions
                )
                self.markClosed()
                self.connection.cancel()
                return
            }
        }
        Task.detached(priority: .utility) { [self] in
            defer { watchdog.cancel() }
            do {
                try await serve()
            } catch {
                Logger.log("LocalSend receive: connection ended with \(error.localizedDescription)", category: .extensions)
            }
            connection.cancel()
            onFinish?()
        }
    }

    private func serve() async throws {
        guard let head = try await readHead() else { return }
        guard let request = LocalSendProtocol.RequestHead(data: head) else {
            // Worth knowing about: it means we answered nothing to a peer.
            let firstLine = String(data: head.prefix(80), encoding: .utf8) ?? "<binary>"
            Logger.log("LocalSend receive: unparsable request head \(firstLine)", category: .extensions)
            return
        }

        switch (request.method, request.path) {
        case ("POST", "/api/localsend/v2/prepare-upload"):
            try await handlePrepareUpload(request)
        case ("POST", "/api/localsend/v2/upload"):
            try await handleUpload(request)
        case ("POST", "/api/localsend/v2/cancel"):
            try await handleCancel(request)
        default:
            // register / info (and anything unknown) stay owned by LocalSendService.
            let declared = min(request.contentLength ?? 0, Self.maximumSmallBodySize)
            let body = declared > 0 ? try await readExactly(declared) : Data()
            var data = head
            data.append(body)
            let response = await MainActor.run {
                LocalSendService.shared.registerResponse(forRequest: data, from: connection.endpoint)
            }
            try await send(response)
        }
    }

    // MARK: prepare-upload

    private func handlePrepareUpload(_ request: LocalSendProtocol.RequestHead) async throws {
        let declared = min(request.contentLength ?? 0, Self.maximumPrepareBodySize)
        let body = declared > 0 ? try await readExactly(declared) : Data()

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawFiles = json["files"] as? [String: Any]
        else {
            try await send(Self.json(status: 400, payload: ["message": "Invalid body"]))
            return
        }

        let senderIP = LocalSendReceiveService.hostString(from: connection.endpoint) ?? "?"
        let incoming: [(id: String, name: String, size: Int, sha256: String?)] = rawFiles.compactMap { key, value in
            guard let file = value as? [String: Any], let name = file["fileName"] as? String else { return nil }
            return (
                id: (file["id"] as? String) ?? key,
                name: name,
                size: (file["size"] as? Int) ?? 0,
                sha256: file["sha256"] as? String
            )
        }

        let alias = ((json["info"] as? [String: Any])?["alias"] as? String) ?? senderIP
        // Watch the connection while the user decides: if the sender gives up it
        // just disconnects, and nothing else would ever tell the card to go away.
        let peerWatch = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await self.waitForPeerClose() else { continue }
                self.markClosed()
                await MainActor.run {
                    LocalSendReceiveService.shared.abandonPendingRequest(senderIP: senderIP)
                }
                return
            }
        }
        defer { peerWatch.cancel() }

        let outcome = await LocalSendReceiveService.shared.prepare(
            files: incoming,
            senderAlias: alias,
            senderIP: senderIP
        )
        switch outcome {
        case .busy:
            try await send(Self.json(status: 409, payload: ["message": "Blocked by another session"]))
        case .emptyFiles:
            try await send(Self.json(status: 400, payload: ["message": "No files provided"]))
        case .declined:
            try await send(Self.json(status: 403, payload: ["message": "Rejected"]))
        case .cancelled:
            try await send(Self.json(status: 403, payload: ["message": "Cancelled by sender"]))
        case .timedOut:
            try await send(Self.json(status: 500, payload: ["message": "Internal server error"]))
        case let .accepted(sessionID, tokens):
            if isClosed {
                // The sender left while the user was deciding: the tokens cannot be
                // delivered, so nobody will ever upload. Releasing here keeps the
                // notch from sitting on "Receiving…" until the idle reaper.
                await MainActor.run {
                    LocalSendReceiveService.shared.abandonUnreachableSession(sessionID: sessionID)
                }
                return
            }
            try await send(Self.json(status: 200, payload: ["sessionId": sessionID, "files": tokens]))
        }
    }

    // MARK: upload

    private func handleUpload(_ request: LocalSendProtocol.RequestHead) async throws {
        guard let sessionID = request.query["sessionId"],
              let fileID = request.query["fileId"],
              let token = request.query["token"]
        else {
            try await send(Self.json(status: 400, payload: ["message": "Missing parameters"]))
            return
        }

        guard LocalSendReceiveService.acquireUploadSlot() else {
            try await send(Self.json(status: 409, payload: ["message": "Too many uploads in progress"]))
            return
        }
        defer { LocalSendReceiveService.releaseUploadSlot() }

        let senderIP = LocalSendReceiveService.hostString(from: connection.endpoint) ?? "?"
        let file = await MainActor.run {
            LocalSendReceiveService.shared.authorizeUpload(
                sessionID: sessionID,
                fileID: fileID,
                token: token,
                senderIP: senderIP
            )
        }
        guard let file else {
            try await send(Self.json(status: 403, payload: ["message": "Invalid token or IP address"]))
            return
        }

        // The declared size is peer-controlled, so never trust it as the cap.
        let maximum = min(file.size > 0 ? file.size : Self.maximumUploadSize, Self.maximumUploadSize)
        let reader: any LocalSendHTTPBody
        if request.isChunked {
            reader = LocalSendChunkedBody(connection: self, maximumBytes: maximum)
        } else if let length = request.contentLength, length <= maximum {
            reader = LocalSendStreamingBody(connection: self, length: length)
        } else {
            try await send(Self.json(status: 400, payload: ["message": "Missing content length"]))
            return
        }
        await MainActor.run {
            LocalSendReceiveService.shared.registerActiveUploadCancellation(fileID: file.id) { [weak self] in
                self?.markClosed()
                self?.connection.cancel()
            }
        }
        let failure = await LocalSendReceiveService.shared.receiveUpload(file: file, body: reader)
        await MainActor.run {
            LocalSendReceiveService.shared.clearActiveUploadCancellation(fileID: file.id)
        }
        if let failure {
            await MainActor.run {
                LocalSendReceiveService.shared.noteUploadFailure(failure, file: file)
            }
            let message: String
            switch failure {
            case .unprocessable: message = "Content hash mismatch"
            case .badRequest: message = "Invalid body"
            default: message = "Internal server error"
            }
            try await send(Self.json(status: failure.statusCode, payload: ["message": message]))
        } else {
            try await send(Self.data(status: 200, body: Data()))
        }
    }

    /// True once the peer has closed the connection (or it failed). Used while the
    /// decision is pending: a sender that gives up simply disconnects.
    private func waitForPeerClose() async -> Bool {
        let connection = self.connection
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: true)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: false)   // unexpected data; keep watching
                } else {
                    continuation.resume(returning: isComplete)
                }
            }
        }
    }

    // MARK: cancel

    /// `POST /api/localsend/v2/cancel` — the sender aborted. v2 senders do not
    /// know the session id before prepare-upload answers, so it may be absent.
    private func handleCancel(_ request: LocalSendProtocol.RequestHead) async throws {
        let senderIP = LocalSendReceiveService.hostString(from: connection.endpoint) ?? "?"
        await MainActor.run {
            LocalSendReceiveService.shared.cancelTransfer(
                sessionID: request.query["sessionId"],
                senderIP: senderIP
            )
        }
        try await send(Self.data(status: 200, body: Data()))
    }

    // MARK: buffered reading

    /// Reads the head (through the blank line). Any body bytes that arrived with
    /// it stay in `buffered`.
    private func readHead() async throws -> Data? {
        while true {
            if let range = buffered.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffered.subdata(in: buffered.startIndex ..< range.upperBound)
                buffered.removeSubrange(buffered.startIndex ..< range.upperBound)
                return head
            }
            if buffered.count > Self.maximumHeadSize { throw LocalSendProtocolError.headTooLarge }
            guard try await fill() else { return nil }
        }
    }

    /// Reads one CRLF-terminated line (chunk headers and their trailers).
    func readLine(maximum: Int) async throws -> String {
        while true {
            if let range = buffered.range(of: Data("\r\n".utf8)) {
                let lineData = buffered.subdata(in: buffered.startIndex ..< range.lowerBound)
                buffered.removeSubrange(buffered.startIndex ..< range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw LocalSendProtocolError.malformedChunk
                }
                return line
            }
            if buffered.count > maximum { throw LocalSendProtocolError.malformedChunk }
            guard try await fill() else { throw LocalSendProtocolError.truncatedBody }
        }
    }

    /// Reads exactly `count` bytes, using anything already buffered first.
    func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            if !buffered.isEmpty {
                let take = min(count - result.count, buffered.count)
                result.append(buffered.prefix(take))
                buffered.removeFirst(take)
                continue
            }
            guard try await fill() else { throw LocalSendProtocolError.truncatedBody }
        }
        return result
    }

    /// Pulls one chunk from the connection into `buffered`; false at EOF.
    ///
    /// A peer that connects and then goes silent must not pin this task (or the
    /// session slot it may hold) forever, so every read races a deadline; on
    /// timeout the connection is cancelled, which also settles the pending
    /// `receive` continuation.
    fileprivate func fill() async throws -> Bool {
        // A peer that connects and then goes silent must not pin this task (or the
        // session slot it holds) forever. A separate deadline task cancels the
        // connection, which settles the pending `receive` below. (Racing receive
        // against a sleep inside a task group does NOT work here: the group waits
        // for every child, and a child parked on a continuation ignores
        // cancellation, so the timeout would only surface once the peer closed.)
        let connection = self.connection
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readDeadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.markClosed()
            connection.cancel()
        }
        defer { deadline.cancel() }

        let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        guard let chunk, !chunk.isEmpty else { return false }
        noteReceived(chunk.count)
        buffered.append(chunk)
        return true
    }

    fileprivate func takeBuffered(_ maximum: Int) -> Data {
        guard !buffered.isEmpty else { return Data() }
        let take = min(maximum, buffered.count)
        let chunk = Data(buffered.prefix(take))
        buffered.removeFirst(take)
        return chunk
    }

    private func send(_ data: Data) async throws {
        guard !isClosed else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: response helpers

    static func json(status: Int, payload: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return data(status: status, body: body, contentType: "application/json")
    }

    static func data(status: Int, body: Data, contentType: String = "application/octet-stream") -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 409: reason = "Conflict"
        case 422: reason = "Unprocessable Entity"
        default: reason = "Internal Server Error"
        }
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}


/// Decodes `Transfer-Encoding: chunked`, which is what LocalSend's senders use
/// when they stream a file without knowing its length up front.
private final class LocalSendChunkedBody: LocalSendHTTPBody, @unchecked Sendable {
    private let source: LocalSendHTTPConnection
    private let maximumBytes: Int
    private var delivered = 0
    private var remainingInChunk = 0
    private var finished = false

    init(connection: LocalSendHTTPConnection, maximumBytes: Int) {
        source = connection
        self.maximumBytes = maximumBytes
    }

    func nextChunk() async throws -> Data? {
        // Consume the current chunk in bounded pieces: a single chunk may claim
        // any size, and buffering it whole would let a peer make us reserve
        // gigabytes (or trap on the arithmetic).
        while remainingInChunk == 0 {
            guard !finished else { return nil }
            let header = try await source.readLine(maximum: 1024)
            let size = try LocalSendProtocol.chunkSize(fromLine: header)
            if size == 0 {
                _ = try? await source.readLine(maximum: 8 * 1024)  // optional trailer
                finished = true
                return nil
            }
            // Overflow-safe by construction: see LocalSendProtocol.acceptingChunkSize.
            delivered = try LocalSendProtocol.acceptingChunkSize(size, delivered: delivered, maximum: maximumBytes)
            remainingInChunk = size
        }

        let piece = try await source.readExactly(min(remainingInChunk, 256 * 1024))
        remainingInChunk -= piece.count
        if remainingInChunk == 0 {
            _ = try await source.readLine(maximum: 16)  // CRLF that follows the data
        }
        return piece
    }
}


/// Streams exactly `length` body bytes off the connection.
private final class LocalSendStreamingBody: LocalSendHTTPBody, @unchecked Sendable {
    private let source: LocalSendHTTPConnection
    private var remaining: Int

    init(connection: LocalSendHTTPConnection, length: Int) {
        source = connection
        remaining = length
    }

    func nextChunk() async throws -> Data? {
        guard remaining > 0 else { return nil }
        let buffered = source.takeBuffered(min(remaining, 256 * 1024))
        if !buffered.isEmpty {
            remaining -= buffered.count
            return buffered
        }
        guard try await source.fill() else { throw LocalSendProtocolError.truncatedBody }
        let chunk = source.takeBuffered(min(remaining, 256 * 1024))
        guard !chunk.isEmpty else { return nil }
        remaining -= chunk.count
        return chunk
    }
}
