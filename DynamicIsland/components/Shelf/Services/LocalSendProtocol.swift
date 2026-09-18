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

/// The byte-level, side-effect-free part of the LocalSend HTTP contract.
///
/// These live outside `LocalSendReceiveService` so they can be exercised
/// directly (`tests/LocalSendProtocolTests`): request lines and chunk-size lines
/// come straight from a peer, which is exactly where a framing bug becomes a
/// crash or a file written to the wrong name. Nothing here touches the network
/// or the filesystem.
enum LocalSendProtocolError: Error, Equatable {
    case headTooLarge
    case truncatedBody
    case malformedChunk
    case tooLarge
}

enum LocalSendProtocol {
    /// A parsed request line plus the headers this server acts on.
    struct RequestHead: Equatable {
        let method: String
        let path: String
        let query: [String: String]
        let contentLength: Int?
        /// Senders streaming a file (the phones do) use chunked framing instead
        /// of a declared length.
        let isChunked: Bool

        init?(data: Data) {
            guard let text = String(data: data, encoding: .utf8),
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
                    let pair = pair.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 {
                        parsed[String(pair[0])] = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                    }
                }
            }
            query = parsed

            let headerLines = text.components(separatedBy: "\r\n")
            contentLength = headerLines
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) }
            isChunked = headerLines.contains {
                $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked")
            }
        }
    }

    /// Reads the size out of a chunk-size line (`1a3f`, optionally
    /// `1a3f;ext=value`). A line that is not a non-negative hex number is a
    /// protocol violation, not something to guess at.
    static func chunkSize(fromLine line: String) throws -> Int {
        let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
            throw LocalSendProtocolError.malformedChunk
        }
        return size
    }

    /// The running total after accepting a chunk of `size` bytes.
    ///
    /// The subtraction happens before the addition on purpose: `delivered + size`
    /// overflows (and traps the process) when a peer announces a chunk of
    /// `Int.max`, which is a remote kill for any accepted session.
    static func acceptingChunkSize(_ size: Int, delivered: Int, maximum: Int) throws -> Int {
        guard size <= maximum - delivered else { throw LocalSendProtocolError.tooLarge }
        return delivered + size
    }

    /// A file name that cannot escape the destination directory: no path
    /// components, no separators, never empty or a dot entry.
    static func sanitizedFileName(_ raw: String) -> String {
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
}
