/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI

/// The notch's confirmation card for an incoming LocalSend transfer.
///
/// Shown inside the expanded notch (the notch opens automatically when a request
/// arrives) so accepting or declining never leaves Atoll's own UI.
struct LocalSendReceiveRequestView: View {
    @ObservedObject var receive = LocalSendReceiveService.shared

    var body: some View {
        Group {
            if let request = receive.pendingRequest {
                requestCard(request)
            } else if let failure = receive.failureText {
                // Ahead of the progress card on purpose: a failure that left the
                // receiving flag set used to hide behind "Receiving…" forever.
                failureCard(failure)
            } else if receive.isReceiving {
                progressCard
            } else if let completion = receive.completionText {
                completionCard(completion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cards

    private func requestCard(_ request: LocalSendIncomingRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incoming files")
                        .font(.system(size: 13, weight: .semibold))
                    Text("From \(request.senderAlias)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    capsuleButton("Decline", filled: false) { receive.declinePendingRequest() }
                    capsuleButton("Accept", filled: true) { receive.acceptPendingRequest() }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(request.files.prefix(3).enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(file.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(file.formattedSize)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if request.files.count > 3 {
                    Text("+ \(request.files.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Declining or ignoring for 60 s tells the sender the transfer failed.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Receiving…")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(Int(receive.receiveProgress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                capsuleButton("Cancel", filled: false) { receive.cancelActiveTransfer() }
            }
            ProgressView(value: min(max(receive.receiveProgress, 0), 1))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func failureCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                capsuleButton("Release", filled: false) { receive.discardFailedTransfer() }
            }
            Text("The sender can retry until the session is released.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func completionCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func capsuleButton(_ title: LocalizedStringKey, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(filled ? Color.accentColor : Color.secondary.opacity(0.18))
                }
                .foregroundStyle(filled ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
