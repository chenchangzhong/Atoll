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

/// Reason an upload was refused, mirroring upstream's HTTP contract.
enum LocalSendReceiveError: Equatable {
    case badRequest
    case forbidden
    case conflict
    case unprocessable
    case server

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .forbidden: return 403
        case .conflict: return 409
        case .unprocessable: return 422
        case .server: return 500
        }
    }
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
    private var sessionStartedAt: Date?
    private var files: [String: LocalSendReceiveFile] = [:]

    /// A sender that walks away would otherwise keep the slot busy forever and
    /// answer every later request with 409.
    private let sessionLifetime: TimeInterval = 5 * 60

    @Published private(set) var receivedCount = 0
    @Published private(set) var receiveProgress: Double = 0
    @Published private(set) var isReceiving = false

    private init() {}

    /// Entry point used by the 53317 listener in `LocalSendService`.
    nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        LocalSendHTTPConnection(connection: connection).start()
    }

    // MARK: - Session lifecycle

    /// Creates a session for a `prepare-upload` request.
    ///
    /// Slice 1 accepts every request; the follow-up replaces this with the
    /// user's decision driven from the notch live activity.
    func beginSession(
        files incoming: [(id: String, name: String, size: Int, sha256: String?)],
        senderIP: String
    ) -> (sessionID: String, tokens: [String: String])? {
        if let startedAt = sessionStartedAt, Date().timeIntervalSince(startedAt) > sessionLifetime {
            Logger.log("LocalSend receive: dropping stale session \(sessionID ?? "?")", category: .extensions)
            sessionID = nil
            self.senderIP = nil
            sessionStartedAt = nil
            files = [:]
        }
        guard sessionID == nil else { return nil }  // 409 while another session is active
        guard !incoming.isEmpty else { return (UUID().uuidString, [:]) }  // 204, nothing to transfer

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
        sessionStartedAt = Date()
        files = accepted
        receivedCount = 0
        receiveProgress = 0
        Logger.log("LocalSend receive: session \(id) prepared for \(accepted.count) file(s) from \(senderIP)", category: .extensions)
        return (id, tokens)
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
                    await MainActor.run { self.receiveProgress = fraction }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            await MainActor.run { self.isReceiving = false }
            Logger.log("LocalSend receive: upload of \(file.name) aborted: \(error.localizedDescription)", category: .extensions)
            return .server
        }

        if let expected = file.sha256, !expected.isEmpty {
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
            if self.files.isEmpty {
                self.sessionID = nil
                self.senderIP = nil
                self.sessionStartedAt = nil
            }
            self.isReceiving = false
            self.receiveProgress = 0
            self.receivedCount += 1
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

    nonisolated static func ipv4(from endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let ip = host.debugDescription.replacingOccurrences(of: "\"", with: "")
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0 ... 255).contains($0) } ?? false }) else { return nil }
        return ip
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

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        Task.detached(priority: .utility) { [self] in
            do {
                try await serve()
            } catch {
                Logger.log("LocalSend receive: connection ended with \(error.localizedDescription)", category: .extensions)
            }
            connection.cancel()
        }
    }

    private func serve() async throws {
        guard let head = try await readHead(), let request = LocalSendHTTPRequest(head: head) else { return }

        switch (request.method, request.path) {
        case ("POST", "/api/localsend/v2/prepare-upload"):
            try await handlePrepareUpload(request)
        case ("POST", "/api/localsend/v2/upload"):
            try await handleUpload(request)
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
            try await send(Self.json(status: 400, payload: ["error": "invalid-body"]))
            return
        }

        let senderIP = LocalSendReceiveService.ipv4(from: connection.endpoint) ?? "?"
        let incoming: [(id: String, name: String, size: Int, sha256: String?)] = rawFiles.compactMap { key, value in
            guard let file = value as? [String: Any], let name = file["fileName"] as? String else { return nil }
            return (
                id: (file["id"] as? String) ?? key,
                name: name,
                size: (file["size"] as? Int) ?? 0,
                sha256: file["sha256"] as? String
            )
        }

        let prepared: (sessionID: String, tokens: [String: String])? = await MainActor.run {
            LocalSendReceiveService.shared.beginSession(files: incoming, senderIP: senderIP)
        }
        guard let session = prepared else {
            try await send(Self.json(status: 409, payload: ["error": "busy"]))
            return
        }

        if session.tokens.isEmpty {
            try await send(Self.data(status: 204, body: Data()))
            return
        }
        try await send(Self.json(status: 200, payload: ["sessionId": session.sessionID, "files": session.tokens]))
    }

    // MARK: upload

    private func handleUpload(_ request: LocalSendHTTPRequest) async throws {
        guard let sessionID = request.query["sessionId"],
              let fileID = request.query["fileId"],
              let token = request.query["token"],
              let length = request.contentLength
        else {
            try await send(Self.json(status: 400, payload: ["error": "missing-parameters"]))
            return
        }

        guard length <= Self.maximumUploadSize else {
            try await send(Self.json(status: 400, payload: ["error": "too-large"]))
            return
        }

        let senderIP = LocalSendReceiveService.ipv4(from: connection.endpoint) ?? "?"
        let file = await MainActor.run {
            LocalSendReceiveService.shared.authorizeUpload(
                sessionID: sessionID,
                fileID: fileID,
                token: token,
                senderIP: senderIP
            )
        }
        guard let file else {
            try await send(Self.json(status: 403, payload: ["error": "invalid-token"]))
            return
        }

        let reader = LocalSendStreamingBody(connection: self, length: length)
        let failure = await LocalSendReceiveService.shared.receiveUpload(file: file, body: reader)
        if let failure {
            try await send(Self.json(status: failure.statusCode, payload: ["error": "upload-failed"]))
        } else {
            try await send(Self.data(status: 200, body: Data()))
        }
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

    /// Reads exactly `count` bytes, using anything already buffered first.
    private func readExactly(_ count: Int) async throws -> Data {
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
    fileprivate func fill() async throws -> Bool {
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
        case 204: reason = "No Content"
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
}

private struct LocalSendHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let contentLength: Int?

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

        contentLength = text
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) }
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
