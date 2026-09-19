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

/// What the receive flow should do about the notch right now.
///
/// This decision cost several rounds of manual debugging — the notch stayed
/// expanded after an answered prompt, then collapsed when it should not have —
/// so the rules live here, free of SwiftUI and Network, and are covered by
/// `tests/LocalSendProtocolTests`.
public struct ReceiveNotchDecision: Equatable {
    /// Keep the auto-close suppression token held.
    public let holdsNotch: Bool
    /// The flow has stopped for good; the caller may release the token and hand
    /// back a notch it owns.
    public let concludes: Bool

    public init(holdsNotch: Bool, concludes: Bool) {
        self.holdsNotch = holdsNotch
        self.concludes = concludes
    }
}

public enum ReceiveNotchPolicy {
    /// How long the flow must stay inactive before the end is believed.
    ///
    /// Accepting passes through an inactive instant: the pending request is
    /// resolved before the session exists, so `isReceiving` is briefly false. A
    /// conclusion drawn from that single moment clears the ownership flag and the
    /// notch then never collapses when the transfer really ends.
    public static let inactivityGrace: TimeInterval = 1.5

    /// Whether to hold the notch open, and whether the flow is over.
    ///
    /// - Parameters:
    ///   - cardVisible: a receive card (prompt, progress, failure, completion)
    ///     wants the notch content.
    ///   - inactiveFor: seconds since any receive state was last active.
    public static func decide(cardVisible: Bool, inactiveFor: TimeInterval) -> ReceiveNotchDecision {
        if cardVisible { return ReceiveNotchDecision(holdsNotch: true, concludes: false) }
        // Inside the grace the flow is only *momentarily* between states: keep the
        // token, so nothing can collapse the notch under a card that is about to
        // come back.
        if inactiveFor <= inactivityGrace { return ReceiveNotchDecision(holdsNotch: true, concludes: false) }
        return ReceiveNotchDecision(holdsNotch: false, concludes: true)
    }

    /// Whether a concluded flow should collapse the notch.
    ///
    /// Only a notch this flow opened is handed back, and never while the user is
    /// pointing at it or another feature is holding it open. A transfer that was
    /// accepted automatically never opened the notch, so it never closes one the
    /// user opened for something else.
    public static func shouldClose(
        ownsNotch: Bool,
        notchOpen: Bool,
        hovering: Bool,
        preventedByOthers: Bool
    ) -> Bool {
        ownsNotch && notchOpen && !hovering && !preventedByOthers
    }
}
