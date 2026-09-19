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

    /// Whether the session slot can go back as soon as the last pending file is
    /// stored, because everything still in the session has already failed.
    public static func releasesSlotImmediately(fileIDs: Set<String>, failedFileIDs: Set<String>) -> Bool {
        !fileIDs.isEmpty && fileIDs.subtracting(failedFileIDs).isEmpty
    }
}
