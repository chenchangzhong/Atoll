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

    /// How long the sender waits for the user before we answer 500.
    private let decisionTimeout: TimeInterval = 60
    /// True while a `prepare` is between publishing its request and creating the
    /// session, so a second request cannot clobber the continuation.
    private var decisionInFlight = false
    private var decisionContinuation: CheckedContinuation<LocalSendReceiveDecision, Never>?
    private var decisionTimeoutTask: Task<Void, Never>?

    private init() {}

    /// Bounds concurrent *uploads* only. register/info must never be refused
    /// because a peer parked upload connections (a drip feed used to exhaust a
    /// global gate and make the whole server unreachable).
    private static let uploadSlots = DispatchSemaphore(value: 4)

    /// Entry point used by the 53317 listener in `LocalSendService`.
    nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        LocalSendHTTPConnection(connection: connection).start()
    }

    // MARK: - Session lifecycle

    /// Outcome of a `prepare-upload`, mapped to the HTTP contract by the caller.
    enum PrepareOutcome {
        case busy
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
            case .timedOut: return .timedOut
            case .accepted: break
            }
        }

        return beginSession(files: incoming, senderIP: senderIP)
    }

    private enum LocalSendReceiveDecision {
        case accepted
        case declined
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
        lastSessionActivity = Date()
        files = accepted
        receiveProgress = 0
        isReceiving = true
        lastReceivedNames = []
        armSessionReaper()
        Logger.log("LocalSend receive: session \(id) prepared for \(accepted.count) file(s) from \(senderIP)", category: .extensions)
        return .accepted(sessionID: id, tokens: tokens)
    }

    /// Releases the session slot and the notch once the transfer has been idle
    /// for `abandonedSessionTimeout` — the sender walked away, or the request was
    /// accepted and no upload ever started. Progress keeps it alive, so a slow
    /// multi-minute upload is not cut off mid-file (a plain per-session deadline
    /// used to do exactly that).
    private func armSessionReaper() {
        sessionReaperTask?.cancel()
        let armed = sessionID
        sessionReaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let idle = await MainActor.run { Date().timeIntervalSince(self.lastSessionActivity) }
                guard idle >= self.abandonedSessionTimeout else { continue }
                await MainActor.run {
                    guard self.sessionID == armed else { return }
                    Logger.log("LocalSend receive: session \(armed ?? "?") idle for \(Int(idle))s; releasing the slot", category: .extensions)
                    self.releaseSession()
                }
                return
            }
        }
    }

    /// Clears the single session slot and everything the notch derives from it.
    private func releaseSession() {
        sessionID = nil
        senderIP = nil
        files = [:]
        isReceiving = false
        receiveProgress = 0
    }

    /// The sender ended the transfer (`POST /api/localsend/v2/cancel`).
    func cancelTransfer(sessionID requested: String?, senderIP: String) {
        if let pending = pendingRequest, pending.senderIP == senderIP {
            resolveDecision(.timedOut)
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
                if file.size > 0 {
                    let fraction = min(1, Double(written) / Double(file.size))
                    await MainActor.run {
                        self.receiveProgress = fraction
                        self.lastSessionActivity = Date()
                    }
                }
            }
        } catch LocalSendHTTPError.tooLarge {
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
            // Stay in the receiving state until the whole session is done, or
            // the notch would flip back between files.
            self.isReceiving = !self.files.isEmpty
            if self.files.isEmpty {
                self.sessionReaperTask?.cancel()
                self.sessionReaperTask = nil
            } else {
                self.armSessionReaper()
            }
            self.receiveProgress = 0
            self.lastSessionActivity = Date()
            return destination
        }

        guard let stored else {
            try? FileManager.default.removeItem(at: temporary)
            return .server
        }
        Logger.log("LocalSend receive: stored \(stored.lastPathComponent) (\(written) bytes)", category: .extensions)
        return nil
    }

    // MARK: - Destination naming

    /// `file (1).txt`, the same shape LocalSend uses, and never a path.
    private func uniqueDestination(for rawName: String) -> URL {
        let name = Self.sanitizedFileName(rawName)
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

    nonisolated static func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (trimmed as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "received-file"
        }
        return cleaned
    }

    /// The peer's address as the transport reports it. Compared verbatim against
    /// the address that prepared the session, so IPv6 peers stay bound too
    /// (returning nil for anything but dotted-quad used to make the check
    /// vacuous).
    nonisolated static func acquireUploadSlot() -> Bool {
        uploadSlots.wait(timeout: .now()) == .success
    }

    nonisolated static func releaseUploadSlot() {
        uploadSlots.signal()
    }

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
    /// Set once the connection is being torn down, so no further reply is
    /// attempted (a stalled read would otherwise leave the response hanging).
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// A request must finish within this window even if it keeps trickling bytes:
    /// the per-read deadline alone would let a one-byte-per-19s peer hold a task
    /// (and an upload slot) indefinitely.
    private static let connectionLifetime: TimeInterval = 30 * 60

    func start() {
        let lifetime = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectionLifetime * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            Logger.log("LocalSend receive: connection exceeded its lifetime", category: .extensions)
            self.isClosed = true
            self.connection.cancel()
        }
        Task.detached(priority: .utility) { [self] in
            defer { lifetime.cancel() }
            do {
                try await serve()
            } catch {
                Logger.log("LocalSend receive: connection ended with \(error.localizedDescription)", category: .extensions)
            }
            connection.cancel()
        }
    }

    private func serve() async throws {
        guard let head = try await readHead() else { return }
        guard let request = LocalSendHTTPRequest(head: head) else {
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

    private func handlePrepareUpload(_ request: LocalSendHTTPRequest) async throws {
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
        let outcome = await LocalSendReceiveService.shared.prepare(
            files: incoming,
            senderAlias: alias,
            senderIP: senderIP
        )
        switch outcome {
        case .busy:
            try await send(Self.json(status: 409, payload: ["message": "Another session is active"]))
        case .emptyFiles:
            try await send(Self.json(status: 400, payload: ["message": "No files provided"]))
        case .declined:
            try await send(Self.json(status: 403, payload: ["message": "Rejected"]))
        case .timedOut:
            try await send(Self.json(status: 500, payload: ["message": "Internal server error"]))
        case let .accepted(sessionID, tokens):
            try await send(Self.json(status: 200, payload: ["sessionId": sessionID, "files": tokens]))
        }
    }

    // MARK: upload

    private func handleUpload(_ request: LocalSendHTTPRequest) async throws {
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
            try await send(Self.json(status: 403, payload: ["message": "Invalid token"]))
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
        let failure = await LocalSendReceiveService.shared.receiveUpload(file: file, body: reader)
        if let failure {
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

    // MARK: cancel

    /// `POST /api/localsend/v2/cancel` — the sender aborted. v2 senders do not
    /// know the session id before prepare-upload answers, so it may be absent.
    private func handleCancel(_ request: LocalSendHTTPRequest) async throws {
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
            if buffered.count > Self.maximumHeadSize { throw LocalSendHTTPError.headTooLarge }
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
                    throw LocalSendHTTPError.malformedChunk
                }
                return line
            }
            if buffered.count > maximum { throw LocalSendHTTPError.malformedChunk }
            guard try await fill() else { throw LocalSendHTTPError.truncatedBody }
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
            guard try await fill() else { throw LocalSendHTTPError.truncatedBody }
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
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isClosed = true
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

private enum LocalSendHTTPError: Error {
    case headTooLarge
    case truncatedBody
    case malformedChunk
    case tooLarge
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
            let sizeText = header.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw LocalSendHTTPError.malformedChunk
            }
            if size == 0 {
                _ = try? await source.readLine(maximum: 8 * 1024)  // optional trailer
                finished = true
                return nil
            }
            // Check before adding: `delivered + size` could overflow and trap.
            guard size <= maximumBytes - delivered else { throw LocalSendHTTPError.tooLarge }
            delivered += size
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

private struct LocalSendHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let contentLength: Int?
    /// Senders streaming a file (the phones do) use chunked framing instead of a
    /// declared length.
    let isChunked: Bool

    init?(head: Data) {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(split[0])

        var parsed: [String: String] = [:]
        if split.count > 1 {
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    parsed[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        query = parsed

        let headerLines = text.components(separatedBy: "\r\n")
        contentLength = headerLines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) }
        isChunked = headerLines.contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
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
        guard try await source.fill() else { throw LocalSendHTTPError.truncatedBody }
        let chunk = source.takeBuffered(min(remaining, 256 * 1024))
        guard !chunk.isEmpty else { return nil }
        remaining -= chunk.count
        return chunk
    }
}
