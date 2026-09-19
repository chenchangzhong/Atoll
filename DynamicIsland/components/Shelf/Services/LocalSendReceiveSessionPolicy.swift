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

/// Which card the notch shows for the receive flow.
public enum ReceiveCard: Equatable {
    case request
    case failure
    case progress
    case completion
    case none
}

/// The receive session decisions that are easy to get wrong.
///
/// Every one of these was a shipped bug at some point — a failure hidden behind a
/// progress card, a failed file keeping the session "receiving" forever, a failure
/// card silently skipped after a cancelled transfer — so they live here as pure
/// functions with tests instead of as inline expressions scattered between the
/// service and the view.
public enum ReceiveSessionPolicy {
    /// The card the notch should render, in priority order.
    ///
    /// A pending request is the only state that needs an answer, so it wins. A
    /// failure must beat progress: it used to be rendered *behind* a progress card
    /// that was never going to move.
    public static func card(
        pendingRequest: Bool,
        failure: Bool,
        receiving: Bool,
        completion: Bool
    ) -> ReceiveCard {
        if pendingRequest { return .request }
        if failure { return .failure }
        if receiving { return .progress }
        if completion { return .completion }
        return .none
    }

    /// Whether the session is still receiving, given the files it still holds.
    ///
    /// A file that failed stays in the session during its retry window, so it must
    /// not count as something to receive: doing so left the progress card up with
    /// nothing left to arrive, and the next sender waiting on a claimed slot.
    public static func isReceiving(fileIDs: Set<String>, failedFileIDs: Set<String>) -> Bool {
        !fileIDs.subtracting(failedFileIDs).isEmpty
    }

    /// Whether a failure still belongs to the session that is active.
    ///
    /// A sender's `/cancel` can race a failing upload: the session is gone by the
    /// time the failure is recorded, and without this the notch would show an
    /// orphan card for a transfer that no longer exists.
    public static func recordsFailure(fileID: String, sessionFileIDs: Set<String>, sessionActive: Bool) -> Bool {
        sessionActive && sessionFileIDs.contains(fileID)
    }

    /// Whether a failed upload should surface a card.
    ///
    /// A cancel the user asked for is not a failure to report. The flag that
    /// carried this was sticky once, so a cancel that arrived when nothing was left
    /// to abort suppressed the *next* transfer's failure card.
    public static func recordsFailureCard(userCancelled: Bool) -> Bool {
        !userCancelled
    }

    /// Whether a cancel from the notch has anything to cancel.
    ///
    /// `cancelActiveTransfer()` needs this: the flag it sets is consumed by the
    /// failure path, so a cancel that arrives when nothing is running used to stay
    /// set and suppress the next transfer's failure card.
    public static func canCancel(isReceiving: Bool, hasSession: Bool) -> Bool {
        isReceiving || hasSession
    }

    /// Whether everything still in the session has already failed, so nothing is
    /// left to receive (the slot is still kept for the failed file's retry window).
    public static func onlyFailuresRemain(fileIDs: Set<String>, failedFileIDs: Set<String>) -> Bool {
        !fileIDs.isEmpty && fileIDs.subtracting(failedFileIDs).isEmpty
    }
}

/// Tracks the connections currently streaming an upload, so a cancel from the notch
/// can tear the right one down.
///
/// Keyed by file id on purpose: the service allows several upload connections at
/// once, and a single slot let the second registration overwrite the first while
/// either one's cleanup cleared the other's.
public struct ActiveUploadCancellations {
    private var cancellations: [String: () -> Void] = [:]

    public init() {}

    public var count: Int { cancellations.count }

    public mutating func register(fileID: String, cancel: @escaping () -> Void) {
        cancellations[fileID] = cancel
    }

    public mutating func clear(fileID: String) {
        cancellations[fileID] = nil
    }

    /// Tears down every upload in flight and reports how many were cancelled.
    @discardableResult
    public mutating func cancelAll() -> Int {
        let cancelled = cancellations.count
        for cancel in cancellations.values { cancel() }
        cancellations.removeAll()
        return cancelled
    }
}

/// The two cancel flags a transfer carries.
///
/// They are a value type because their lifetime is the bug: `userCancelled` is
/// consumed by the failure path, so a cancel that arrives when nothing is left to
/// abort used to stay set and suppress the *next* transfer's failure card. Starting
/// an upload resets both, and consuming one resets both.
public struct ReceiveUploadFlags: Equatable {
    public private(set) var cancelRequested = false
    public private(set) var userCancelled = false

    public init() {}

    public mutating func beginUpload() {
        cancelRequested = false
        userCancelled = false
    }

    public mutating func requestCancel() {
        cancelRequested = true
        userCancelled = true
    }

    /// Returns whether the abort was user-requested, clearing both flags.
    public mutating func consumeUserCancelled() -> Bool {
        let wasCancelled = userCancelled
        beginUpload()
        return wasCancelled
    }
}

public extension ReceiveSessionPolicy {
    /// Whether the session a caller is acting on is still the active one (a newer
    /// transfer may have replaced it in the meantime).
    static func isCurrentSession(_ sessionID: String?, expected: String) -> Bool {
        sessionID == expected
    }
}
