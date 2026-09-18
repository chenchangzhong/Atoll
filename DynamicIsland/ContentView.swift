/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import Combine
import Defaults
import Foundation
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @EnvironmentObject var webcamManager: WebcamManager

    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    @ObservedObject var privacyManager = PrivacyIndicatorManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject var lockScreenManager = LockScreenManager.shared
    @ObservedObject var capsLockManager = CapsLockManager.shared
    @ObservedObject var localSendService = LocalSendService.shared
    @ObservedObject var localSendReceiveService = LocalSendReceiveService.shared
    @State private var downloadManager = DownloadManager.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    
    @Default(.showCapsLockLabel) var showCapsLockLabel
    @Default(.capsLockIndicatorTintMode) var capsLockTintMode
    @Default(.enableDoNotDisturbDetection) var enableDoNotDisturbDetection
    @Default(.showDoNotDisturbIndicator) var showDoNotDisturbIndicator
    @Default(.enableScreenRecordingDetection) var enableScreenRecordingDetection
    @Default(.enableCapsLockIndicator) var enableCapsLockIndicator
    @Default(.showStandardMediaControls) var showStandardMediaControls
    @Default(.externalDisplayStyle) var externalDisplayStyle
    @Default(.hideNonNotchUntilHover) var hideNonNotchUntilHover
    
    // Battery settings reactivity
    @Default(.showPowerStatusNotifications) var showPowerStatusNotifications
    @Default(.showChargingBatteryHUD) var showChargingBatteryHUD
    @Default(.showLowBatteryHUD) var showLowBatteryHUD
    @Default(.showFullBatteryHUD) var showFullBatteryHUD
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.lowBatteryHUDStyle) var lowBatteryHUDStyle
    @Default(.fullBatteryHUDStyle) var fullBatteryHUDStyle
    
    // Dynamic sizing based on view type and graph count with smooth transitions
    var dynamicNotchSize: CGSize {
        let baseSize = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize(isDynamicIslandMode: isDynamicIslandMode) : openNotchSize
        
        // When inline sneak peek is active in closed notch, use the wider inline width
        // so the outer maxWidth frame doesn't clip the expanded content
        let airPodsListeningModeSneakActive = vm.notchState == .closed
            && coordinator.sneakPeek.show
            && coordinator.sneakPeek.type == .bluetoothAudio
            && coordinator.sneakPeek.value < 0
            && AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil
        let inlineSneakPeekActive = vm.notchState == .closed
            && (
                coordinator.expandingView.show
                    && (coordinator.expandingView.type == .music)
                    && Defaults[.sneakPeekStyles] == .inline
                || airPodsListeningModeSneakActive
            )
            && Defaults[.enableSneakPeek]
        if inlineSneakPeekActive {
            let inlineWidth: CGFloat = airPodsListeningModeSneakActive
                ? InlineHUD.airPodsListeningModeWidth(
                    closedNotchWidth: vm.closedNotchSize.width,
                    gestureProgress: gestureProgress,
                    minimalistic: Defaults[.enableMinimalisticUI]
                ) + notchHorizontalPadding * 2
                : 460
            return CGSize(width: max(baseSize.width, inlineWidth), height: baseSize.height)
        }
        
        // Handle battery HUD expansion sizing
        if vm.notchState == .closed && 
           coordinator.expandingView.show && 
           coordinator.expandingView.type == .battery &&
           isBatteryHUDVisibleOnCurrentScreen {
            
            if let kind = batteryModel.activeTemporaryHUDKind {
                let style: BatteryNotificationStyle = {
                    switch kind {
                    case .charging: return .compact
                    case .lowBattery: return Defaults[.lowBatteryHUDStyle]
                    case .fullBattery: return Defaults[.fullBatteryHUDStyle]
                    }
                }()
                
                var width = vm.closedNotchSize.width
                var height = vm.effectiveClosedNotchHeight
                
                switch (kind, style) {
                case (.charging, _), (.lowBattery, .compact), (.fullBattery, .compact):
                    width += 180
                case (.lowBattery, .standard):
                    width += 100
                    height += 75
                case (.fullBattery, .standard):
                    width += 80
                    height += 70
                }
                
                return CGSize(width: width, height: height)
            }
        }
        
        return baseSize
    }
    

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var lastHapticTime: Date = Date()
    @State private var hoverClickMonitor: Any?
    @State private var hoverClickLocalMonitor: Any?
    @State private var hiddenEdgeHoverPollingTask: Task<Void, Never>?
    @State private var isHoveringClosedMusicWaveformControl: Bool = false

    @State private var gestureProgress: CGFloat = .zero
    @State private var isMusicControlWindowVisible = false
    @State private var pendingMusicControlTask: Task<Void, Never>?
    @State private var musicControlHideTask: Task<Void, Never>?
    @State private var musicControlVisibilityDeadline: Date?
    @State private var isMusicControlWindowSuppressed = false
    @State private var hasPendingMusicControlSync = false
    @State private var pendingMusicControlForceRefresh = false
    @State private var musicControlSuppressionTask: Task<Void, Never>?

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.musicControlWindowEnabled) var musicControlWindowEnabled
    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.useModernCloseAnimation) var useModernCloseAnimation
    @Default(.enableMinimalisticUI) var enableMinimalisticUI

    private static let musicControlLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func logMusicControlEvent(_ message: String) {
#if DEBUG
        let timestamp = Self.musicControlLogFormatter.string(from: Date())
        print("[MusicControl] \(timestamp): \(message)")
#endif
    }

    private func runAfter(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        guard delay >= 0 else { return }
        Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            action()
        }
    }

    private func requestMusicControlWindowSyncIfHidden(forceRefresh: Bool = false, delay: TimeInterval = 0) {
        guard !isMusicControlWindowVisible else { return }
        enqueueMusicControlWindowSync(forceRefresh: forceRefresh, delay: delay)
    }
    private var dynamicNotchResizeAnimation: Animation? {
        nil
    }
    
    private let zeroHeightHoverPadding: CGFloat = 10
    private let musicControlPauseGrace: TimeInterval = 5
    private let musicControlResumeDelay: TimeInterval = 0.24

    // MARK: - Tab switch direction for smooth transitions
    
    private var tabSwitchTransition: AnyTransition {
        if coordinator.tabSwitchForward {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        } else {
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
    
    private var standardMediaControlsActive: Bool {
        showStandardMediaControls && !enableMinimalisticUI
    }

    private var closedMusicContentEnabled: Bool {
        enableMinimalisticUI || showStandardMediaControls
    }

    private var isMusicHUDDeferredAfterUnlock: Bool {
        lockScreenManager.shouldDelayPostUnlockMusicHUD
    }

    private var interactionsEnabled: Bool {
        !lockScreenManager.isLocked
    }

    private var isIslandMode: Bool {
        isDynamicIslandMode
    }

    private var notchHorizontalPadding: CGFloat {
        guard vm.notchState == .open else {
            return activeCornerRadiusInsets.closed.bottom
        }
        if Defaults[.cornerRadiusScaling] {
            return activeCornerRadiusInsets.opened.top - 5
        }
        return activeCornerRadiusInsets.opened.bottom - 5
    }

    private var bodyHoverAreaPadding: CGFloat {
        if vm.notchState == .open && Defaults[.extendHoverArea] {
            return 0
        }
        return vm.effectiveClosedNotchHeight == 0 ? zeroHeightHoverPadding : 0
    }

    private var notchBottomPadding: CGFloat {
        currentShadowPadding + bodyHoverAreaPadding
    }

    private var pillTopOffset: CGFloat {
        isIslandMode ? dynamicIslandTopOffset : 0
    }

    private func closedMusicPairingEligible(hasActiveMusicSnapshot: Bool) -> Bool {
        vm.notchState == .closed
            && hasActiveMusicSnapshot
            && coordinator.musicLiveActivityEnabled
            && closedMusicContentEnabled
            && !vm.hideOnClosed
            && !lockScreenManager.isLocked
            && !isMusicHUDDeferredAfterUnlock
    }

    private var closedLiveActivitySwapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.965, anchor: .center))
                .animation(.spring(response: 0.34, dampingFraction: 0.88)),
            removal: .opacity
                .combined(with: .scale(scale: 0.92, anchor: .center))
                .animation(.smooth(duration: 0.22))
        )
    }
    
    // Use minimalistic corner radius ONLY when opened, keep normal when closed
    private var activeCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) {
        if enableMinimalisticUI {
            // Keep normal closed corner radius, use minimalistic when opened
            return (opened: minimalisticCornerRadiusInsets.opened, closed: cornerRadiusInsets.closed)
        }
        return cornerRadiusInsets
    }
    
    private var currentShadowPadding: CGFloat {
        notchShadowPaddingValue(isMinimalistic: enableMinimalisticUI)
    }

    private var currentNotchShape: NotchShape {
        let topRadius = (vm.notchState == .open && Defaults[.cornerRadiusScaling])
            ? activeCornerRadiusInsets.opened.top
            : activeCornerRadiusInsets.closed.top
        let bottomRadius = (vm.notchState == .open && Defaults[.cornerRadiusScaling])
            ? activeCornerRadiusInsets.opened.bottom
            : activeCornerRadiusInsets.closed.bottom
        return NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
    }

    /// Whether the current screen should render as a Dynamic Island pill
    /// rather than the standard notch shape. Always false on physical notch screens.
    private var isDynamicIslandMode: Bool {
        shouldUseDynamicIslandMode(for: currentScreenName)
    }

    private var currentScreenName: String {
        vm.screen ?? coordinator.selectedScreen
    }

    /// Whether the current screen lacks a physical notch.
    private var isNonNotchScreen: Bool {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == currentScreenName }) else {
            return true
        }
        return screen.safeAreaInsets.top <= 0
    }

    /// Whether the global sneak peek is visible on this specific screen.
    private var isSneakPeekVisibleOnCurrentScreen: Bool {
        guard coordinator.sneakPeek.show else { return false }
        guard Defaults[.showOnAllDisplays] else { return true }
        guard let targetScreenName = coordinator.sneakPeek.targetScreenName else { return true }
        return currentScreenName == targetScreenName
    }

    /// Whether the notch/island should hide off-screen when closed on a non-notch display.
    /// Temporarily reveals the notch when a sneakPeek HUD (volume, brightness, music, etc.) is active.
    private var shouldHideUntilHover: Bool {
        hideNonNotchUntilHover && isNonNotchScreen && vm.notchState == .closed && !isSneakPeekVisibleOnCurrentScreen
    }

    /// Whether the fallback top-edge hover detector should run.
    /// This is only needed when the notch is fully hidden off-screen and
    /// regular `.onHover` hit-testing may not trigger reliably.
    private var shouldUseHiddenEdgeHoverPolling: Bool {
        shouldHideUntilHover && !lockScreenManager.isLocked
    }
    
    /// Whether the LocalSend live activity should be shown
    private var localSendLiveActivityActive: Bool {
        localSendService.isSending || 
        localSendService.transferState == .completed ||
        isLocalSendFailedOrRejected
    }
    
    private var isLocalSendFailedOrRejected: Bool {
        if case .failed = localSendService.transferState { return true }
        if case .rejected = localSendService.transferState { return true }
        return false
    }

    /// Pill shape for Dynamic Island mode with animated corner radius transitions.
    private var currentPillShape: DynamicIslandPillShape {
        let radius: CGFloat
        if vm.notchState == .open {
            radius = enableMinimalisticUI
                ? minimalisticCornerRadiusInsets.opened.top
                : dynamicIslandPillCornerRadiusInsets.opened
        } else {
            // Use half the closed height for a true capsule shape
            radius = max(vm.closedNotchSize.height / 2, dynamicIslandPillCornerRadiusInsets.closed.standard)
        }
        return DynamicIslandPillShape(cornerRadius: radius)
    }

    private var isBatteryHUDVisibleOnCurrentScreen: Bool {
        guard coordinator.expandingView.show, coordinator.expandingView.type == .battery else { return false }
        guard showPowerStatusNotifications else { return false }
        guard batteryModel.activeTemporaryHUDKind != nil else { return false }
        if showOnAllDisplays { return true }
        guard let targetScreenName = batteryModel.activeTemporaryHUDTargetScreenName else { return true }
        return currentScreenName == targetScreenName
    }

    private var isCurrentScreenExpansionVisible: Bool {
        guard coordinator.expandingView.show else { return false }
        if coordinator.expandingView.type == .battery {
            return isBatteryHUDVisibleOnCurrentScreen
        }
        return true
    }

    private var currentScreenExpansionType: SneakContentType? {
        isCurrentScreenExpansionVisible ? coordinator.expandingView.type : nil
    }

    private var displayedBatteryHUDLevel: Int {
        let resolvedLevel = batteryModel.activeTemporaryHUDLevelOverride
            ?? Int(batteryModel.levelBattery.rounded())
        return min(max(resolvedLevel, 0), 100)
    }

    private var displayedBatteryHUDUsesLowPowerMode: Bool {
        batteryModel.activeTemporaryHUDLowPowerModeOverride ?? batteryModel.isInLowPowerMode
    }


    private var activeClosedBatterySurfaceShape: AnyShape? {
        guard vm.notchState == .closed else { return nil }
        guard isBatteryHUDVisibleOnCurrentScreen else { return nil }
        guard let kind = batteryModel.activeTemporaryHUDKind else { return nil }

        if isDynamicIslandMode {
            let radius = dynamicIslandPillCornerRadiusInsets.opened
            return AnyShape(DynamicIslandPillShape(cornerRadius: radius))
        } else {
            let topRadius = activeCornerRadiusInsets.closed.top
            let bottomRadius: CGFloat = {
                switch resolvedBatteryNotificationStyle(for: kind) {
                case .compact:
                    return activeCornerRadiusInsets.closed.bottom
                case .standard:
                    return kind == .fullBattery ? 36 : 40
                }
            }()
            return AnyShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
        }
    }

    private func resolvedBatteryNotificationStyle(for kind: BatteryTemporaryHUDKind) -> BatteryNotificationStyle {
        switch kind {
        case .charging:
            return .compact
        case .lowBattery:
            return lowBatteryHUDStyle
        case .fullBattery:
            return fullBatteryHUDStyle
        }
    }


    /// Resolves the clip/content shape per-screen: pill on non-notch screens
    /// when dynamic island mode is active, standard notch shape otherwise.
    private var resolvedClipShape: AnyShape {
        if let activeClosedBatterySurfaceShape {
            return activeClosedBatterySurfaceShape
        }
        if isDynamicIslandMode {
            return AnyShape(currentPillShape)
        }
        return AnyShape(currentNotchShape)
    }

    var body: some View {
        installRootLifecycleHandlers(on: rootBodyView)
    }

    private var mainLayoutBase: some View {
        NotchLayout()
            .frame(alignment: .top)
            .padding(.horizontal, notchHorizontalPadding)
            .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
            .background(.black)
            .clipShape(resolvedClipShape)
            .compositingGroup()
            .shadow(
                color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                    ? .black.opacity(0.6)
                    : .clear,
                radius: Defaults[.cornerRadiusScaling] ? 10 : 5
            )
            // Extra horizontal inset for Dynamic Island mode so the shadow
            // is not clipped by the outer frame constraint
            .padding(.horizontal, isIslandMode ? dynamicIslandShadowInset : 0)
            .padding(.bottom, isIslandMode ? dynamicIslandShadowInset : 0)
            .padding(.top, pillTopOffset)
            .accessibilityIdentifier("AtollNotch")
    }

    private var configuredMainLayout: some View {
        mainLayoutBase
            .conditionalModifier(!useModernCloseAnimation) { view in
                let hoverAnimation = Animation.bouncy.speed(1.2)
                let notchStateAnimation = Animation.spring.speed(1.2)
                return view
                    .animation(hoverAnimation, value: isHovering)
                    .animation(notchStateAnimation, value: vm.notchState)
                    .animation(.smooth, value: gestureProgress)
                    .transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
            }
            .conditionalModifier(useModernCloseAnimation) { view in
                let hoverAnimation = Animation.bouncy.speed(1.2)
                let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                let notchAnimation = vm.notchState == .open ? openAnimation : closeAnimation
                return view
                    .animation(hoverAnimation, value: isHovering)
                    .animation(notchAnimation, value: vm.notchState)
                    .animation(.smooth, value: gestureProgress)
            }
            .conditionalModifier(interactionsEnabled) { view in
                view
                    .contentShape(resolvedClipShape)
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if handleClosedMusicWaveformTapIfNeeded() {
                            return
                        }
                        if vm.notchState == .closed && Defaults[.enableHaptics] {
                            triggerHapticIfAllowed()
                        }
                        openNotch()
                    }
            }
            // Shadow bottom padding and hide-until-hover offset applied AFTER
            // interaction modifiers so .contentShape / .onHover only covers
            // the actual notch content, not the shadow clearance below it.
            .padding(.bottom, notchBottomPadding)
            .offset(y: shouldHideUntilHover && !isHovering
                ? -(vm.closedNotchSize.height + pillTopOffset + currentShadowPadding + 10)
                : 0
            )
            .onAppear(perform: {
                if coordinator.firstLaunch {
                    // Single open during first launch; closeHello() handles the timed close.
                    runAfter(1) {
                        withAnimation(vm.animation) {
                            openNotch()
                        }
                    }
                }
            })
            .onChange(of: vm.notchState) { _, newState in
                // Reset hover state when notch state changes
                if newState == .closed && isHovering {
                    withAnimation {
                        isHovering = false
                    }
                }
                if newState != .closed {
                    isHoveringClosedMusicWaveformControl = false
                }
            }
            .onChange(of: vm.isBatteryPopoverActive) { _, newPopoverState in
                runAfter(0.1) {
                    if !newPopoverState && !isHovering && vm.notchState == .open && !shouldPreventAutoClose() {
                        vm.close()
                    }
                }
            }
            .onChange(of: vm.shouldRecheckHover) { _, _ in
                // Recheck hover state when popovers are closed
                runAfter(0.1) {
                    if vm.notchState == .open && !shouldPreventAutoClose() && !isHovering {
                        vm.close()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                runAfter(0.1) {
                    if vm.notchState == .open && !isHovering && !shouldPreventAutoClose() {
                        vm.close()
                    }
                }
            }
            .onChange(of: coordinator.sneakPeek.show) { _, sneakPeekShowing in
                // When sneak peek finishes, check if user is still hovering and open notch if needed
                if !sneakPeekShowing {
                    runAfter(0.2) {
                        if isHovering && vm.notchState == .closed && !coordinator.isHoverOpenSuppressed {
                            openNotch()
                        }
                    }
                }
            }
            .sensoryFeedback(.alignment, trigger: haptics)
            .contextMenu {
                Button("Settings") {
                    SettingsWindowController.shared.showWindow()
                }
//                Button("Edit") { // Doesnt work....
//                    let dn = DynamicNotch(content: EditPanelView())
//                    dn.toggle()
//                }
//                #if DEBUG
//                .disabled(false)
//                #else
//                .disabled(true)
//                #endif
//                .keyboardShortcut("E", modifiers: .command)
            }
    }

    private var rootBodyView: some View {
        ZStack(alignment: .top) {
            configuredMainLayout
        }
        .frame(
            maxWidth: (dynamicNotchSize.width + (vm.notchState == .open ? 24 : 0) + (isDynamicIslandMode ? dynamicIslandShadowInset * 2 : 0)).rounded(),
            maxHeight: (dynamicNotchSize.height + (vm.notchState == .open ? 12 : 0) + (isDynamicIslandMode ? dynamicIslandTopOffset + dynamicIslandShadowInset * 2 : currentShadowPadding)).rounded(),
            alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(privacyManager)
        .background(dragDetector)
        .environmentObject(vm)
        .environmentObject(webcamManager)
    }

    private func installRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        installSecondaryRootLifecycleHandlers(
            on: installPrimaryRootLifecycleHandlers(on: view)
        )
    }

    private func installPrimaryRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        view
            .onAppear {
                isMusicControlWindowSuppressed = vm.notchState != .closed
                    || lockScreenManager.isLocked
                    || isMusicHUDDeferredAfterUnlock
                if musicManager.isPlaying || !musicManager.isPlayerIdle {
                    clearMusicControlVisibilityDeadline()
                }
                if let deadline = musicControlVisibilityDeadline, Date() > deadline {
                    clearMusicControlVisibilityDeadline()
                }
                enqueueMusicControlWindowSync(forceRefresh: true)
                startHiddenEdgeHoverPolling()
                // Deterministic teardown for borderless panels (`.onDisappear` is
                // unreliable); the window-cleanup path calls this before closing.
                vm.onViewTeardown = { performViewTeardown() }
            }
            .onChange(of: vm.notchState) { _, state in
                if state == .open {
                    suppressMusicControlWindowUpdates()
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                } else {
                    releaseMusicControlWindowUpdates(after: musicControlResumeDelay)
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: 0.05)
                }
            }
            .onChange(of: musicControlWindowEnabled) { _, enabled in
                if enabled {
                    if musicManager.isPlaying || !musicManager.isPlayerIdle {
                        clearMusicControlVisibilityDeadline()
                    }
                    enqueueMusicControlWindowSync(forceRefresh: true)
                } else {
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                    clearMusicControlVisibilityDeadline()
                    hasPendingMusicControlSync = false
                    pendingMusicControlForceRefresh = false
                }
            }
            .onChange(of: coordinator.musicLiveActivityEnabled) { _, enabled in
                if enabled {
                    enqueueMusicControlWindowSync(forceRefresh: true)
                } else {
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                    clearMusicControlVisibilityDeadline()
                    hasPendingMusicControlSync = false
                    pendingMusicControlForceRefresh = false
                }
            }
            .onChange(of: vm.hideOnClosed) { _, hidden in
                if hidden {
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                } else {
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: 0.05)
                }
            }
            .onChange(of: lockScreenManager.isLocked) { _, locked in
                if locked {
                    suppressMusicControlWindowUpdates()
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                } else {
                    releaseMusicControlWindowUpdates(after: musicControlResumeDelay)
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: 0.05)
                }
            }
            .onChange(of: lockScreenManager.shouldDelayPostUnlockMusicHUD) { _, deferred in
                if deferred {
                    suppressMusicControlWindowUpdates()
                    cancelMusicControlWindowSync()
                    hideMusicControlWindow()
                } else {
                    releaseMusicControlWindowUpdates(after: 0)
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: 0.05)
                }
            }
    }

    private func installSecondaryRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        view
            .onChange(of: showStandardMediaControls) { _, _ in
                handleStandardMediaControlsAvailabilityChange()
            }
            .onChange(of: enableMinimalisticUI) { _, _ in
                handleStandardMediaControlsAvailabilityChange()
            }
            .onChange(of: gestureProgress) { _, _ in
                if shouldShowMusicControlWindow() {
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: 0.05)
                }
            }
            .onChange(of: isHovering) { _, hovering in
                if shouldShowMusicControlWindow() {
                    enqueueMusicControlWindowSync(forceRefresh: true, delay: hovering ? 0.05 : 0.12)
                }
            }
            .onChange(of: musicManager.isPlaying) { _, isPlaying in
                handleMusicControlPlaybackChange(isPlaying: isPlaying)
            }
            .onChange(of: musicManager.isPlayerIdle) { _, isIdle in
                handleMusicControlIdleChange(isIdle: isIdle)
            }
            .onChange(of: vm.closedNotchSize) { _, _ in
                if shouldShowMusicControlWindow() {
                    enqueueMusicControlWindowSync(forceRefresh: true)
                }
            }
            .onChange(of: vm.effectiveClosedNotchHeight) { _, _ in
                if shouldShowMusicControlWindow() {
                    enqueueMusicControlWindowSync(forceRefresh: true)
                }
            }
            .onDisappear {
                performViewTeardown()
            }
    }

    @ViewBuilder
      func NotchLayout() -> some View {
          VStack(alignment: .leading) {
              VStack(alignment: .leading) {
                  if coordinator.firstLaunch {
                      Spacer()
                      HelloAnimation().frame(width: 200, height: 80).onAppear(perform: {
                          vm.closeHello()
                      })
                      .padding(.top, 40)
                      Spacer()
                  } else {
                        let hasMusicMetadata = !musicManager.songTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                            || !musicManager.artistName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                      let hasActiveMusicSnapshot: Bool = {
                          if musicManager.isPlaying { return true }
                          return !musicManager.isPlayerIdle && hasMusicMetadata
                      }()
                      let musicPairingEligible = closedMusicPairingEligible(hasActiveMusicSnapshot: hasActiveMusicSnapshot)
                      let musicSecondary = resolveMusicSecondaryLiveActivity(isMusicPairingEligible: musicPairingEligible)
                      let activeSneakPeekStyle = resolvedSneakPeekStyle()
                      let expansionMatchesSecondary: Bool = {
                          guard let musicSecondary else { return false }
                          switch musicSecondary {
                          case .recording:
                              return currentScreenExpansionType == .recording
                          case .focus:
                              return currentScreenExpansionType == .doNotDisturb
                          case .capsLock:
                              return false
                          case .shelf:
                              return false
                          }
                      }()
                      let canShowMusicDuringExpansion = !isCurrentScreenExpansionVisible
                          || currentScreenExpansionType == .music
                          || expansionMatchesSecondary
                      let isAirPodsListeningModeSneak = coordinator.sneakPeek.type == .bluetoothAudio
                          && coordinator.sneakPeek.value < 0
                          && AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil

                      if currentScreenExpansionType == .battery
                            && isBatteryHUDVisibleOnCurrentScreen
                            && vm.notchState == .closed
                            && Defaults[.showPowerStatusNotifications]
                            && batteryModel.activeTemporaryHUDKind != nil {
                        BatteryTemporaryActivityView(
                            kind: batteryModel.activeTemporaryHUDKind ?? .charging,
                            batteryLevel: displayedBatteryHUDLevel,
                            isLowPowerMode: displayedBatteryHUDUsesLowPowerMode,
                            closedNotchWidth: vm.closedNotchSize.width + (isHovering ? 8 : 0),
                            baseHeight: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0),
                            isDynamicIslandMode: isDynamicIslandMode,
                            topCornerRadius: activeCornerRadiusInsets.closed.top,
                            styleOverride: batteryModel.activeTemporaryHUDKind.map { resolvedBatteryNotificationStyle(for: $0) }
                        )
                        .id(batteryModel.activeTemporaryHUDToken)
                      } else if isSneakPeekVisibleOnCurrentScreen && (Defaults[.inlineHUD] || isAirPodsListeningModeSneak) && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && ((coordinator.sneakPeek.type != .volume && coordinator.sneakPeek.type != .brightness && coordinator.sneakPeek.type != .backlight) || vm.notchState == .closed) {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(
                                  coordinator.sneakPeek.type == .capsLock
                                      ? AnyTransition.move(edge: .trailing).combined(with: .opacity)
                                      : AnyTransition.opacity
                              )
                      } else if vm.notchState == .closed && capsLockManager.isCapsLockActive && Defaults[.enableCapsLockIndicator] && !vm.hideOnClosed && !lockScreenManager.isLocked {
                          InlineHUD(type: .constant(.capsLock), value: .constant(1.0), icon: .constant(""), hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
                      } else if canShowMusicDuringExpansion && musicPairingEligible {
                          MusicLiveActivity(secondary: musicSecondary)
                              .id("closed-music-live-activity")
                              .transition(closedLiveActivitySwapTransition)
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .recording) && vm.notchState == .closed && (recordingManager.isRecording || !recordingManager.isRecorderIdle) && Defaults[.enableScreenRecordingDetection] && !vm.hideOnClosed && !musicPairingEligible {
                          RecordingLiveActivity()
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .download) && vm.notchState == .closed && downloadManager.isDownloading && Defaults[.enableDownloadListener] && !vm.hideOnClosed {
                          DownloadLiveActivity()
                              .transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
                      } else if !isCurrentScreenExpansionVisible && vm.notchState == .closed && localSendLiveActivityActive && !vm.hideOnClosed {
                          LocalSendLiveActivity()
                              .transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .doNotDisturb) && vm.notchState == .closed && Defaults[.enableDoNotDisturbDetection] && Defaults[.showDoNotDisturbIndicator] && (doNotDisturbManager.isDoNotDisturbActive || doNotDisturbManager.isFocusToastDismissing) && !vm.hideOnClosed && !lockScreenManager.isLocked {
                          DoNotDisturbLiveActivity()
                    } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .lockScreen) && vm.notchState == .closed && (lockScreenManager.isLocked || !lockScreenManager.isLockIdle) && Defaults[.enableLockScreenLiveActivity] && !vm.hideOnClosed {
                        LockScreenLiveActivity()
                            .id("lock-screen-live-activity")
                            .transition(closedLiveActivitySwapTransition)
                    } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .privacy) && vm.notchState == .closed && privacyManager.hasAnyIndicator && (Defaults[.enableCameraDetection] || Defaults[.enableMicrophoneDetection]) && !vm.hideOnClosed {
                        PrivacyLiveActivity()
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && !shelfState.isEmpty && !vm.hideOnClosed && !lockScreenManager.isLocked && !enableMinimalisticUI {
                          ShelfInlineLiveActivity()
                              .transition(.opacity.animation(.smooth(duration: 0.25)))
                      } else if !coordinator.expandingView.show && !isCurrentScreenExpansionVisible && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          DynamicIslandFaceAnimation().animation(.interactiveSpring, value: musicManager.isPlayerIdle)
                      } else if vm.notchState == .open {
                          DynamicIslandHeader()
                              .frame(height: (Defaults[.enableMinimalisticUI] && isDynamicIslandMode) ? nil : max(24, vm.effectiveClosedNotchHeight))
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }
                      
                      if isSneakPeekVisibleOnCurrentScreen {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .capsLock) && !Defaults[.inlineHUD] && !isAirPodsListeningModeSneak && ((coordinator.sneakPeek.type != .volume && coordinator.sneakPeek.type != .brightness && coordinator.sneakPeek.type != .backlight) || vm.notchState == .closed) {
                              SystemEventIndicatorModifier(eventType: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, sendEventBack: { _ in
                                  //
                              })
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && activeSneakPeekStyle == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName), textColor: .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier(shouldFixSizeForSneakPeek()) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
              
              ZStack {
                  if vm.notchState == .open {
                      Group {
                          // An incoming transfer takes over the expanded notch so
                          // the user can accept or decline without leaving Atoll.
                          if localSendReceiveService.pendingRequest != nil
                              || localSendReceiveService.isReceiving
                              || localSendReceiveService.completionText != nil {
                              LocalSendReceiveRequestView()
                          } else {
                              switch coordinator.currentView {
                                  case .home:
                                      NotchHomeView(albumArtNamespace: albumArtNamespace)
                                  case .shelf:
                                      NotchShelfView()
                              }
                          }
                      }
                      .id(coordinator.currentView)
                      .transition(tabSwitchTransition)
                  }
              }
              .onChange(of: localSendReceiveService.pendingRequest) { _, request in
                  // The user chose to be told about incoming files, so open the
                  // notch rather than waiting for a hover.
                  if request != nil {
                      withAnimation(.smooth(duration: 0.3)) {
                          vm.open()
                      }
                  }
              }
              .zIndex(1)
              .allowsHitTesting(vm.notchState == .open)
              .blur(radius: abs(gestureProgress) > 0.3 ? min(abs(gestureProgress), 8) : 0)
              .opacity(abs(gestureProgress) > 0.3 ? min(abs(gestureProgress * 2), 0.8) : 1)
              .animation(.smooth(duration: 0.3), value: coordinator.currentView)
          }
      }

    @ViewBuilder
    func DynamicIslandFaceAnimation() -> some View {
        let sideSize = max(0, vm.effectiveClosedNotchHeight - 12)
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(width: sideSize, height: sideSize)
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                IdleAnimationView()
                    .frame(width: sideSize, height: sideSize)
            }
        }.frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
    }

    @ViewBuilder
    private func MusicLiveActivity(secondary preResolvedSecondary: MusicSecondaryLiveActivity? = nil) -> some View {
        let secondary = preResolvedSecondary ?? resolveMusicSecondaryLiveActivity()
        let notchContentHeight = max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12))
        let wingBaseWidth = max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2)
        let rawCenterBaseWidth = vm.closedNotchSize.width + (isHovering ? 8 : 0)
        let centerBaseWidth = max(rawCenterBaseWidth, 96)
        let inlineSneakPeekActive = (
            coordinator.expandingView.show &&
            (coordinator.expandingView.type == .music) &&
            Defaults[.enableSneakPeek] &&
            Defaults[.sneakPeekStyles] == .inline
        )
        let rightWingWidth = resolvedRightWingWidth(
            for: secondary,
            baseWidth: wingBaseWidth,
            centerBaseWidth: centerBaseWidth,
            notchHeight: notchContentHeight
        )
        let effectiveCenterWidth = inlineSneakPeekActive ? 380 : centerBaseWidth
        let notchWidth = wingBaseWidth + effectiveCenterWidth + rightWingWidth
        let badgeBaseSize = max(13, notchContentHeight * 0.36)
        let badgeDisplaySize = badgeDisplaySize(for: secondary, baseSize: badgeBaseSize)
        let badgeOffset = badgeOverlayOffset(for: secondary, badgeSize: badgeDisplaySize)

        HStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        Image(nsImage: musicManager.albumArt)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: musicManager.albumArt.size.width/musicManager.albumArt.size.height > 1.0 ? MusicPlayerImageSizes.cornerRadiusInset.closed/3.0 : MusicPlayerImageSizes.cornerRadiusInset.closed))
                    )
                    .clipped()
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                    .albumArtFlip(angle: musicManager.flipAngle)
                albumArtBadge(for: secondary, badgeSize: badgeDisplaySize)
                    .offset(x: badgeOffset.width, y: badgeOffset.height)
                    .id(secondary?.id ?? "music-badge")
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: wingBaseWidth, height: notchContentHeight)

            Rectangle()
                .fill(.black)
                .frame(width: effectiveCenterWidth, height: notchContentHeight)
                .overlay(
                    HStack(alignment: .top) {
                        if(coordinator.expandingView.show && coordinator.expandingView.type == .music) {
                            MusicTitleMarqueeView(
                                text: musicManager.songTitle,
                                isExplicit: musicManager.isCurrentTrackExplicit,
                                textColor: Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: max(0, (effectiveCenterWidth - vm.closedNotchSize.width) / 2 - 12),
                                badgeHeight: 13
                            )
                            .padding(.leading, 8)
                            .opacity((coordinator.expandingView.show && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray)
                                .padding(.trailing, 8)
                                .opacity((coordinator.expandingView.show && coordinator.expandingView.type == .music && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
} else if Defaults[.showSongMetadataInClosedNotch] && isNonNotchScreen && !musicManager.songTitle.isEmpty {
                            MarqueeText(
                                .constant("\(musicManager.songTitle) • \(musicManager.artistName)"),
                                textColor: Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 3,
                                frameWidth: max(0, effectiveCenterWidth - 16)
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .clipped()
                )

            musicRightWing(for: secondary, notchHeight: notchContentHeight, trailingWidth: rightWingWidth)
                .frame(width: rightWingWidth, height: notchContentHeight, alignment: .center)
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard shouldShowClosedMusicWaveformPlayPauseOverlay(for: secondary) else {
                        if isHoveringClosedMusicWaveformControl {
                            isHoveringClosedMusicWaveformControl = false
                        }
                        return
                    }
                    withAnimation(.smooth(duration: 0.16)) {
                        isHoveringClosedMusicWaveformControl = hovering
                    }
                }
                .id(secondary?.id ?? "music-spectrum")
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: notchWidth, height: notchContentHeight)
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
        .animation(.smooth(duration: 0.25), value: secondary?.id)
    }

    private func resolveMusicSecondaryLiveActivity(isMusicPairingEligible: Bool = true) -> MusicSecondaryLiveActivity? {
        if enableScreenRecordingDetection && (recordingManager.isRecording || !recordingManager.isRecorderIdle) {
            return .recording
        }

        if enableDoNotDisturbDetection && showDoNotDisturbIndicator && doNotDisturbManager.isDoNotDisturbActive {
            let mode = FocusModeType.resolve(identifier: doNotDisturbManager.currentFocusModeIdentifier, name: doNotDisturbManager.currentFocusModeName)
            return .focus(mode)
        }

        if enableCapsLockIndicator && capsLockManager.isCapsLockActive {
            return .capsLock(showLabel: showCapsLockLabel)
        }

        // Shelf: show file count as lowest-priority secondary
        if !shelfState.isEmpty && !lockScreenManager.isLocked && !enableMinimalisticUI {
            return .shelf(count: shelfState.items.count)
        }

        return nil
    }

    private func resolvedRightWingWidth(for secondary: MusicSecondaryLiveActivity?, baseWidth: CGFloat, centerBaseWidth: CGFloat, notchHeight: CGFloat) -> CGFloat {
        guard let secondary else { return baseWidth }

        switch secondary {
        case .capsLock(let showLabel):
            return showLabel ? scaledWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth, factor: 0.4, extra: 12) : baseWidth
        case .focus:
            return focusRightWingWidth(baseWidth: baseWidth)
        case .recording:
            return recordingRightWingWidth(baseWidth: baseWidth)
        case .shelf:
            return baseWidth
        }
    }

    private func focusRightWingWidth(baseWidth: CGFloat) -> CGFloat {
        // Focus pairings now mirror the default music spectrum width to keep the notch compact.
        return baseWidth
    }

    private func recordingRightWingWidth(baseWidth: CGFloat) -> CGFloat {
        // Keep recording pairings compact by reducing the width relative to the notch height.
        let absoluteMin: CGFloat = 38
        let preferredWidth = max(baseWidth * 0.6, 0)
        let maxWidth = min(baseWidth - 6, 52)
        let clampedPreferred = min(preferredWidth, maxWidth)
        return min(baseWidth, max(absoluteMin, clampedPreferred))
    }

    private func scaledWingWidth(baseWidth: CGFloat, centerBaseWidth: CGFloat, factor: CGFloat, extra: CGFloat) -> CGFloat {
        max(baseWidth, max(centerBaseWidth * factor, baseWidth + extra))
    }

    @ViewBuilder
    private func albumArtBadge(for secondary: MusicSecondaryLiveActivity?, badgeSize: CGFloat) -> some View {
        if let secondary, badgeSize > 0 {
            ZStack {
                Circle()
                    .fill(Color.black)

                switch secondary {
                case .focus(let mode):
                    mode.resolvedActiveIcon(usePrivateSymbol: true)
                        .renderingMode(.template)
                        .font(.system(size: badgeSize * 0.5, weight: .semibold))
                        .foregroundStyle(mode.accentColor)
                case .recording:
                    Circle()
                        .fill(Color.red)
                        .frame(width: badgeSize * 0.45, height: badgeSize * 0.45)
                        .modifier(PulsingModifier())
                case .capsLock:
                    Image(systemName: "capslock.fill")
                        .font(.system(size: badgeSize * 0.5, weight: .semibold))
                        .foregroundStyle(capsLockTintMode.color)
                case .shelf:
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: badgeSize * 0.50, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: badgeSize, height: badgeSize)
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .transition(.opacity.combined(with: .scale))
        } else {
            EmptyView()
        }
    }

    private func badgeDisplaySize(for secondary: MusicSecondaryLiveActivity?, baseSize: CGFloat) -> CGFloat {
        guard let secondary else { return baseSize }
        switch secondary {
        default:
            return baseSize
        }
    }

    private func badgeOverlayOffset(for secondary: MusicSecondaryLiveActivity?, badgeSize: CGFloat) -> CGSize {
        guard let secondary else { return CGSize(width: badgeSize * 0.2, height: badgeSize * 0.25) }
        switch secondary {
        default:
            return CGSize(width: badgeSize * 0.2, height: badgeSize * 0.25)
        }
    }

    @ViewBuilder
    private func musicRightWing(for secondary: MusicSecondaryLiveActivity?, notchHeight: CGFloat, trailingWidth: CGFloat) -> some View {
        switch secondary {
        case .capsLock(let showLabel):
            if showLabel {
                MusicCapsLockLabelView(color: capsLockTintMode.color)
            } else {
                spectrumView(forceSpectrum: true)
            }
        case .focus:
            spectrumView(forceSpectrum: true)
        case .recording:
            spectrumView(forceSpectrum: true, trailingInset: 6)
        case .shelf(let count):
            // File count badge: bold white number, like a minimal pill
            Text("\(count)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: false))
                .animation(.smooth(duration: 0.3), value: count)
                .frame(alignment: .center)
        case .none:
            spectrumView(
                forceSpectrum: false,
                enableClosedPlayPauseOverlay: shouldShowClosedMusicWaveformPlayPauseOverlay(for: secondary)
            )
        }
    }

    @ViewBuilder
    private func SpectrumVisualizer(
        useMusicVisualizer: Bool,
        forceSpectrum: Bool
    ) -> some View {
        let width = CGFloat(Defaults[.visualizerBarCount]) * 4
        if useMusicVisualizer || forceSpectrum {
            Rectangle()
                .fill((Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray).spectrogramGradient())
                .frame(width: 50, alignment: .center)
                .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                .mask {
                    AudioVisualizerView(isPlaying: $musicManager.isPlaying)
                        .frame(width: width, height: 12)
                }
        }
    }

    @ViewBuilder
    private func spectrumView(
        forceSpectrum: Bool,
        trailingInset: CGFloat = 0,
        enableClosedPlayPauseOverlay: Bool = false
    ) -> some View {
        if useMusicVisualizer || forceSpectrum {
            SpectrumVisualizer(useMusicVisualizer: useMusicVisualizer, forceSpectrum: forceSpectrum)
                .blur(radius: (enableClosedPlayPauseOverlay && isHoveringClosedMusicWaveformControl) ? 2.4 : 0)
                .overlay {
                    if enableClosedPlayPauseOverlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(isHoveringClosedMusicWaveformControl ? 0.24 : 0.02))

                            Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(isHoveringClosedMusicWaveformControl ? 0.98 : 0.0))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, trailingInset)
                .animation(.smooth(duration: 0.16), value: isHoveringClosedMusicWaveformControl)
                .animation(.smooth(duration: 0.2), value: musicManager.isPlaying)
        } else {
            LottieAnimationView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    var dragDetector: some View {
        if lockScreenManager.isLocked {
            EmptyView()
        } else if Defaults[.dynamicShelf] && !Defaults[.enableMinimalisticUI] {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.data], isTargeted: $vm.dragDetectorTargeting) { _ in true }
                .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
                    if isTargeted, vm.notchState == .closed {
                        coordinator.currentView = .shelf
                        openNotch()
                    } else if !isTargeted {
                        if vm.dropEvent {
                            vm.dropEvent = false
                            return
                        }

                        vm.dropEvent = false
                        if !shouldPreventAutoClose() {
                            vm.close()
                        }
                    }
                }
        } else {
            EmptyView()
        }
    }

    // MARK: - Private Methods
    private func openNotch() {
        withAnimation(.bouncy.speed(1.2)) {
            vm.open()
        }
    }

    private func shouldShowClosedMusicWaveformPlayPauseOverlay(for secondary: MusicSecondaryLiveActivity?) -> Bool {
        guard secondary == nil else { return false }
        return isClosedMusicGestureContext && !Defaults[.openNotchOnHover]
    }

    private var isClosedMusicGestureContext: Bool {
        vm.notchState == .closed
            && coordinator.musicLiveActivityEnabled
            && closedMusicContentEnabled
            && !vm.hideOnClosed
            && !lockScreenManager.isLocked
            && !isMusicHUDDeferredAfterUnlock
            && !isCurrentScreenExpansionVisible
            && (!musicManager.isPlayerIdle || musicManager.bundleIdentifier != nil)
            && !coordinator.firstLaunch
    }

    private func handleClosedMusicWaveformTapIfNeeded() -> Bool {
        guard shouldShowClosedMusicWaveformPlayPauseOverlay(for: nil),
              isHoveringClosedMusicWaveformControl else {
            return false
        }

        if Defaults[.enableHaptics] {
            triggerHapticIfAllowed()
        }
        musicManager.playPause()
        return true
    }

    private func hiddenHoverActivationContainsMouse(_ location: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == currentScreenName }) else {
            return false
        }

        let horizontalPadding: CGFloat = 8
        let activationWidth = vm.closedNotchSize.width + horizontalPadding * 2
        let activationHeight = max(vm.closedNotchSize.height + zeroHeightHoverPadding, 14)

        let activationRect = CGRect(
            x: screen.frame.midX - activationWidth / 2,
            y: screen.frame.maxY - activationHeight,
            width: activationWidth,
            height: activationHeight
        )

        return activationRect.contains(location)
    }

    /// Cancels every long-lived task / event monitor this view owns. Called from
    /// `.onDisappear` and from `vm.onViewTeardown` on window close. Idempotent.
    private func performViewTeardown() {
        hoverTask?.cancel()
        stopHoverClickMonitor()
        stopHiddenEdgeHoverPolling()
        cancelMusicControlWindowSync()
        hideMusicControlWindow()
        cancelMusicControlVisibilityTimer()
        clearMusicControlVisibilityDeadline()
        musicControlSuppressionTask?.cancel()
        isHoveringClosedMusicWaveformControl = false
    }

    private func startHiddenEdgeHoverPolling() {
        guard hiddenEdgeHoverPollingTask == nil else { return }

        hiddenEdgeHoverPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                if self.shouldUseHiddenEdgeHoverPolling {
                    let hovering = self.hiddenHoverActivationContainsMouse()
                    if hovering != self.isHovering {
                        self.handleHover(hovering)
                    }
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            self.hiddenEdgeHoverPollingTask = nil
        }
    }

    private func stopHiddenEdgeHoverPolling() {
        hiddenEdgeHoverPollingTask?.cancel()
        hiddenEdgeHoverPollingTask = nil
    }

    private func startHoverClickMonitor() {
        guard Defaults[.openNotchOnHover] else { return }
        guard hoverClickMonitor == nil else { return }

        let handleClick: @Sendable () -> Void = { [weak vm, weak lockScreenManager] in
            Task { @MainActor in
                guard let vm, let lockScreenManager else { return }
                guard !lockScreenManager.isLocked else { return }
                guard vm.notchState == .closed else { return }
                guard !self.coordinator.isHoverOpenSuppressed else { return }
                guard self.isHovering else { return }
                guard !self.handleClosedMusicWaveformTapIfNeeded() else { return }
                if Defaults[.enableHaptics] {
                    self.triggerHapticIfAllowed()
                }
                self.openNotch()
            }
        }

        // Global monitor catches clicks outside the app window (e.g. when
        // the cursor is at the very top screen edge and the click goes to
        // the system rather than our panel).
        hoverClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            handleClick()
        }

        // Local monitor catches clicks that DO hit our window — at the
        // screen edge SwiftUI's .onTapGesture may not fire reliably, but
        // the NSEvent local monitor will.
        hoverClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handleClick()
            return event
        }
    }

    private func stopHoverClickMonitor() {
        if let hoverClickMonitor {
            NSEvent.removeMonitor(hoverClickMonitor)
            self.hoverClickMonitor = nil
        }
        if let hoverClickLocalMonitor {
            NSEvent.removeMonitor(hoverClickLocalMonitor)
            self.hoverClickLocalMonitor = nil
        }
    }

    /// Installs the global outside-click monitor whenever the Terminal tab is open
    /// (e.g. keyboard-opened terminal), regardless of sticky mode.
    ///
    // MARK: - Hover Management
    
    /// Handle hover state changes with debouncing
    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            startHoverClickMonitor()
        } else {
            stopHoverClickMonitor()
            if isHoveringClosedMusicWaveformControl {
                withAnimation(.smooth(duration: 0.16)) {
                    isHoveringClosedMusicWaveformControl = false
                }
            }
        }

        if hovering {
            withAnimation(.bouncy.speed(1.2)) {
                isHovering = true
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                triggerHapticIfAllowed()
            }

            guard vm.notchState == .closed,
                !isSneakPeekVisibleOnCurrentScreen,
                Defaults[.openNotchOnHover] else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.isSneakPeekVisibleOnCurrentScreen,
                          !self.coordinator.isHoverOpenSuppressed else { return }

                    self.openNotch()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.bouncy.speed(1.2)) {
                        self.isHovering = false
                    }

                    if self.vm.notchState == .open && !self.shouldPreventAutoClose() {
                        self.vm.close()
                    }
                }
            }
        }
    }

    private func isPointInsideNotchWindow(_ point: CGPoint) -> Bool {
        if let appDelegate = AppDelegate.shared {
            if Defaults[.showOnAllDisplays] {
                return appDelegate.windows.values.contains(where: { $0.frame.contains(point) })
            }
            if let window = appDelegate.window {
                return window.frame.contains(point)
            }
        }

        return NSApp.windows.contains(where: { $0.frame.contains(point) })
    }
    
    // Helper function to check if any popovers are active
    private func hasAnyActivePopovers() -> Bool {
     return vm.isBatteryPopoverActive ||
         vm.isMediaOutputPopoverActive
    }

    private func shouldPreventAutoClose() -> Bool {
        coordinator.firstLaunch || hasAnyActivePopovers() || vm.isAutoCloseSuppressed || SharingStateManager.shared.preventNotchClose
    }
    
    // Helper to prevent rapid haptic feedback
    private func triggerHapticIfAllowed() {
        let now = Date()
        if now.timeIntervalSince(lastHapticTime) > 0.3 { // Minimum 300ms between haptics
            haptics.toggle()
            lastHapticTime = now
        }
    }
    
    private func handleMusicControlPlaybackChange(isPlaying: Bool) {
        guard musicControlWindowEnabled else { return }

        if isPlaying {
            clearMusicControlVisibilityDeadline()
            requestMusicControlWindowSyncIfHidden()
        } else {
            extendMusicControlVisibilityAfterPause()
        }
    }

    private func handleMusicControlIdleChange(isIdle: Bool) {
        guard musicControlWindowEnabled else { return }

        if isIdle {
            if musicControlVisibilityDeadline == nil {
                extendMusicControlVisibilityAfterPause()
            }
        } else if musicManager.isPlaying {
            clearMusicControlVisibilityDeadline()
        }
    }

    private func handleStandardMediaControlsAvailabilityChange() {
        guard musicControlWindowEnabled else {
            hideMusicControlWindow()
            return
        }

        if standardMediaControlsActive {
            if musicManager.isPlaying || !musicManager.isPlayerIdle {
                clearMusicControlVisibilityDeadline()
            }
            enqueueMusicControlWindowSync(forceRefresh: true)
        } else {
            cancelMusicControlWindowSync()
            hideMusicControlWindow()
            clearMusicControlVisibilityDeadline()
            hasPendingMusicControlSync = false
            pendingMusicControlForceRefresh = false
        }
    }

    private func extendMusicControlVisibilityAfterPause() {
        let deadline = Date().addingTimeInterval(musicControlPauseGrace)
        musicControlVisibilityDeadline = deadline
        scheduleMusicControlVisibilityCheck(deadline: deadline)
        requestMusicControlWindowSyncIfHidden()
    }

    private func clearMusicControlVisibilityDeadline() {
        musicControlVisibilityDeadline = nil
        cancelMusicControlVisibilityTimer()
    }

    private func scheduleMusicControlVisibilityCheck(deadline: Date) {
        cancelMusicControlVisibilityTimer()

        let interval = max(0, deadline.timeIntervalSinceNow)

        musicControlHideTask = Task.detached(priority: .background) { [interval] in
            if interval > 0 {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if let currentDeadline = musicControlVisibilityDeadline, currentDeadline <= Date() {
                    musicControlVisibilityDeadline = nil
                }

                enqueueMusicControlWindowSync(forceRefresh: false)

                musicControlHideTask = nil
            }
        }
    }

    private func cancelMusicControlVisibilityTimer() {
        musicControlHideTask?.cancel()
        musicControlHideTask = nil
    }

    private func musicControlVisibilityIsActive() -> Bool {
        if musicManager.isPlaying {
            return true
        }

        guard let deadline = musicControlVisibilityDeadline else { return false }
        return Date() <= deadline
    }

    private func suppressMusicControlWindowUpdates() {
        isMusicControlWindowSuppressed = true
        musicControlSuppressionTask?.cancel()
        musicControlSuppressionTask = nil
    }

    private func releaseMusicControlWindowUpdates(after delay: TimeInterval) {
        musicControlSuppressionTask?.cancel()
        musicControlSuppressionTask = Task { [delay] in
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if vm.notchState == .closed && !lockScreenManager.isLocked && !isMusicHUDDeferredAfterUnlock {
                    isMusicControlWindowSuppressed = false
                    triggerPendingMusicControlSyncIfNeeded()
                } else {
                    isMusicControlWindowSuppressed = true
                }
                musicControlSuppressionTask = nil
            }
        }
    }

    private func triggerPendingMusicControlSyncIfNeeded() {
        guard hasPendingMusicControlSync else { return }

        let shouldForce = pendingMusicControlForceRefresh
        hasPendingMusicControlSync = false
        pendingMusicControlForceRefresh = false

        logMusicControlEvent("Flushing pending floating window sync (force: \(shouldForce))")
        scheduleMusicControlWindowSync(forceRefresh: shouldForce, bypassSuppression: true)
    }

    private func shouldDeferMusicControlSync() -> Bool {
        vm.notchState != .closed
            || lockScreenManager.isLocked
            || isMusicHUDDeferredAfterUnlock
            || isMusicControlWindowSuppressed
    }

    private func enqueueMusicControlWindowSync(forceRefresh: Bool, delay: TimeInterval = 0) {
        if shouldDeferMusicControlSync() {
            hasPendingMusicControlSync = true
            if forceRefresh {
                pendingMusicControlForceRefresh = true
            }
            logMusicControlEvent("Queued floating window sync (force: \(forceRefresh)) while deferred")
            return
        }

        logMusicControlEvent("Scheduling floating window sync (force: \(forceRefresh), delay: \(delay))")
        scheduleMusicControlWindowSync(forceRefresh: forceRefresh, delay: delay)
    }

    private func shouldShowMusicControlWindow() -> Bool {
        guard musicControlWindowEnabled,
              coordinator.musicLiveActivityEnabled,
              standardMediaControlsActive,
              vm.notchState == .closed,
              !vm.hideOnClosed,
              !lockScreenManager.isLocked,
              !isMusicHUDDeferredAfterUnlock,
              !isMusicControlWindowSuppressed else {
            return false
        }

        return musicControlVisibilityIsActive()
    }

    private func scheduleMusicControlWindowSync(forceRefresh: Bool, delay: TimeInterval = 0, bypassSuppression: Bool = false) {
        #if os(macOS)
        cancelMusicControlWindowSync()

        guard shouldShowMusicControlWindow() else {
            hasPendingMusicControlSync = false
            pendingMusicControlForceRefresh = false
            hideMusicControlWindow()
            return
        }

        if !bypassSuppression && (isMusicControlWindowSuppressed || lockScreenManager.isLocked || isMusicHUDDeferredAfterUnlock) {
            hasPendingMusicControlSync = true
            if forceRefresh {
                pendingMusicControlForceRefresh = true
            }
            return
        }

        hasPendingMusicControlSync = false
        pendingMusicControlForceRefresh = false

        let syncDelay = max(0, delay)

        pendingMusicControlTask = Task.detached(priority: .userInitiated) { [forceRefresh, syncDelay] in
            if syncDelay > 0 {
                let nanoseconds = UInt64(syncDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if shouldShowMusicControlWindow() {
                    logMusicControlEvent("Running floating window sync (force: \(forceRefresh))")
                    syncMusicControlWindow(forceRefresh: forceRefresh)
                } else {
                    logMusicControlEvent("Skipping floating window sync (conditions changed)")
                    hideMusicControlWindow()
                }

                pendingMusicControlTask = nil
            }
        }
        #endif
    }

    private func cancelMusicControlWindowSync() {
        pendingMusicControlTask?.cancel()
        pendingMusicControlTask = nil
    }

    #if os(macOS)
    private func currentMusicControlWindowMetrics() -> MusicControlWindowMetrics {
        MusicControlWindowMetrics(
            notchHeight: max(vm.closedNotchSize.height, vm.effectiveClosedNotchHeight),
            notchWidth: vm.closedNotchSize.width + (isHovering ? 8 : 0),
            rightWingWidth: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2),
            cornerRadius: activeCornerRadiusInsets.closed.bottom,
            spacing: 36
        )
    }

    private func syncMusicControlWindow(forceRefresh: Bool = false) {
        let notchAvailable = vm.effectiveClosedNotchHeight > 0 && vm.closedNotchSize.width > 0
        let targetVisible = shouldShowMusicControlWindow() && notchAvailable

        if targetVisible {
            let metrics = currentMusicControlWindowMetrics()
            if !isMusicControlWindowVisible {
                let didPresent = MusicControlWindowManager.shared.present(using: vm, metrics: metrics)
                isMusicControlWindowVisible = didPresent
            } else if forceRefresh {
                let didRefresh = MusicControlWindowManager.shared.refresh(using: vm, metrics: metrics)
                if !didRefresh {
                    MusicControlWindowManager.shared.hide()
                    isMusicControlWindowVisible = false
                }
            }
        } else if isMusicControlWindowVisible {
            MusicControlWindowManager.shared.hide()
            isMusicControlWindowVisible = false
        }
    }

    private func hideMusicControlWindow() {
        if isMusicControlWindowVisible {
            MusicControlWindowManager.shared.hide()
            isMusicControlWindowVisible = false
        }
    }
    #else
    private func syncMusicControlWindow(forceRefresh: Bool = false) {}

    private func hideMusicControlWindow() {}
    #endif
    
    private func shouldFixSizeForSneakPeek() -> Bool {
        guard isSneakPeekVisibleOnCurrentScreen else { return false }
        let style = resolvedSneakPeekStyle()
        
        // Original logic for other types
        let isMusicSneak = coordinator.sneakPeek.type == .music && vm.notchState == .closed && !vm.hideOnClosed && style == .standard
        let isOtherSneak = coordinator.sneakPeek.type != .music && vm.notchState == .closed
        
        return isMusicSneak || isOtherSneak
    }

    private func resolvedSneakPeekStyle() -> SneakPeekStyle {
        return coordinator.sneakPeek.styleOverride ?? Defaults[.sneakPeekStyles]
    }
}

private enum MusicSecondaryLiveActivity: Equatable {
    case recording
    case focus(FocusModeType)
    case capsLock(showLabel: Bool)
    case shelf(count: Int)

    var id: String {
        switch self {
        case .recording:
            return "recording"
        case .focus(let mode):
            return "focus-\(mode.rawValue)"
        case .capsLock(let showLabel):
            return showLabel ? "caps-lock-label" : "caps-lock-icon"
        case .shelf(let count):
            return "shelf-\(count)"
        }
    }
}

private struct MusicCapsLockLabelView: View {
    let color: Color

    var body: some View {
        Text("Caps Lock")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentTransition(.opacity)
    }
}

#if canImport(AppKit)
private typealias MusicSupplementFont = NSFont
#elseif canImport(UIKit)
private typealias MusicSupplementFont = UIFont
#endif

private func musicMeasureText(_ text: String, font: MusicSupplementFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    return CGFloat(ceil(NSAttributedString(string: text, attributes: attributes).size().width))
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }
}
