//
//  SettingsView.swift
//  DynamicIsland
//
//  Created by Richard Kunkli on 07/08/2024.
//
import AppKit
import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

/// Groups for organizing settings tabs in the sidebar.
private enum SettingsTabGroup: String, CaseIterable, Identifiable {
    case core
    case mediaAndDisplay
    case system
    case utilities
    case info

    var id: String { rawValue }

    /// Display title for the section header.  `nil` means no visible header.
    var title: String? {
        switch self {
        case .core:             return nil
        case .mediaAndDisplay:  return String(localized: "Media & Display")
        case .system:           return String(localized: "System")
        case .utilities:        return String(localized: "Utilities")
        case .info:             return nil
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case liveActivities
    case appearance
    case lockScreen
    case media
    case devices
    case hudAndOSD
    case battery
    case downloads
    case shelf
    case shortcuts
    case about

    var id: String { rawValue }

    /// Which sidebar group this tab belongs to.
    var group: SettingsTabGroup {
        switch self {
        case .general, .appearance:                                          return .core
        case .media, .liveActivities, .lockScreen, .devices:                 return .mediaAndDisplay
        case .hudAndOSD, .battery:                                           return .system
        case .shelf,
             .downloads, .shortcuts:                                         return .utilities
        case .about:                                                         return .info
        }
    }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .liveActivities: return String(localized: "Live Activities")
        case .appearance: return String(localized: "Appearance")
        case .lockScreen: return String(localized: "Lock Screen")
        case .media: return String(localized: "Media")
        case .devices: return String(localized: "Devices")
        case .hudAndOSD: return String(localized: "Controls")
        case .battery: return String(localized: "Battery")
        case .downloads: return String(localized: "Downloads")
        case .shelf: return String(localized: "Shelf")
        case .shortcuts: return String(localized: "Shortcuts")
        case .about: return String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gear"
        case .liveActivities: return "waveform.path.ecg"
        case .appearance: return "paintpalette"
        case .lockScreen: return "lock.laptopcomputer"
        case .media: return "play.laptopcomputer"
        case .devices: return "headphones"
        case .hudAndOSD: return "dial.medium.fill"
        case .battery: return "battery.100.bolt"
        case .downloads: return "square.and.arrow.down"
        case .shelf: return "books.vertical"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .blue
        case .liveActivities: return .pink
        case .appearance: return .purple
        case .lockScreen: return .orange
        case .media: return .green
        case .devices: return Color(red: 0.1, green: 0.11, blue: 0.12)
        case .hudAndOSD: return .indigo
        case .battery: return Color(red: 0.202, green: 0.783, blue: 0.348, opacity: 1.000)
        case .downloads: return .gray
        case .shelf: return .brown
        case .shortcuts: return .orange
        case .about: return .secondary
        }
    }

    func highlightID(for title: String) -> String {
        "\(rawValue)-\(title)"
    }
}

private struct SettingsSearchEntry: Identifiable {
    let tab: SettingsTab
    let title: String
    let keywords: [String]
    let highlightID: String?

    var id: String { "\(tab.rawValue)-\(title)" }
}

final class SettingsHighlightCoordinator: ObservableObject {
    struct ScrollRequest: Identifiable, Equatable {
        let id: String
        fileprivate let tab: SettingsTab
    }

    @Published fileprivate var pendingScrollRequest: ScrollRequest?
    @Published private(set) var activeHighlightID: String?

    private var clearWorkItem: DispatchWorkItem?

    fileprivate func focus(on entry: SettingsSearchEntry) {
        guard let highlightID = entry.highlightID else { return }
        pendingScrollRequest = ScrollRequest(id: highlightID, tab: entry.tab)
        activateHighlight(id: highlightID)
    }

    func consumeScrollRequest(_ request: ScrollRequest) {
        guard pendingScrollRequest?.id == request.id else { return }
        pendingScrollRequest = nil
    }

    private func activateHighlight(id: String) {
        activeHighlightID = id
        clearWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard self?.activeHighlightID == id else { return }
            self?.activeHighlightID = nil
        }

        clearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }
}

private struct SettingsHighlightModifier: ViewModifier {
    let id: String
    @EnvironmentObject private var highlightCoordinator: SettingsHighlightCoordinator
    @State private var animatePulse = false

    private var isActive: Bool {
        highlightCoordinator.activeHighlightID == id
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .background(highlightBackground)
            .onChange(of: isActive) { _, active in
                animatePulse = active
            }
            .onAppear {
                if isActive {
                    animatePulse = true
                }
            }
    }

    private var highlightBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(
                Color.accentColor.opacity(isActive ? (animatePulse ? 0.95 : 0.4) : 0),
                lineWidth: 2
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(isActive ? 0.08 : 0))
            )
            .padding(-4)
            .shadow(color: Color.accentColor.opacity(isActive ? 0.25 : 0), radius: animatePulse ? 8 : 2)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: animatePulse
            )
    }
}

extension View {
    func settingsHighlight(id: String) -> some View {
        modifier(SettingsHighlightModifier(id: id))
    }

    @ViewBuilder
    func settingsHighlightIfPresent(_ id: String?) -> some View {
        if let id {
            settingsHighlight(id: id)
        } else {
            self
        }
    }
}

private struct SettingsForm<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var highlightCoordinator: SettingsHighlightCoordinator

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .onReceive(highlightCoordinator.$pendingScrollRequest.compactMap { request -> SettingsHighlightCoordinator.ScrollRequest? in
                    guard let request, request.tab == tab else { return nil }
                    return request
                }) { request in
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(request.id, anchor: .center)
                    }
                    highlightCoordinator.consumeScrollRequest(request)
                }
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var searchText: String = ""
    @StateObject private var highlightCoordinator = SettingsHighlightCoordinator()
    @Default(.enableMinimalisticUI) var enableMinimalisticUI

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                SettingsSidebarSearchBar(
                    text: $searchText,
                    suggestions: searchSuggestions,
                    onSuggestionSelected: handleSearchSuggestionSelection
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Divider()
                    .padding(.horizontal, 12)

                List(selection: selectionBinding) {
                    ForEach(groupedFilteredTabs, id: \.group) { section in
                        Section {
                            ForEach(section.tabs) { tab in
                                NavigationLink(value: tab) {
                                    sidebarRow(for: tab)
                                }
                            }
                        } header: {
                            if let title = section.group.title {
                                Text(title)
                            }
                        }
                    }
                }
                .listStyle(SidebarListStyle())
                .frame(minWidth: 200)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
                .environment(\.defaultMinListRowHeight, 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } detail: {
            detailView(for: resolvedSelection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar { toolbarSpacingShim }
        .environmentObject(highlightCoordinator)
        .formStyle(.grouped)
        .frame(width: 700)
        .onChange(of: searchText) { _, newValue in
            let matches = tabsMatchingSearch(newValue)
            guard let firstMatch = matches.first else { return }
            if !matches.contains(resolvedSelection) {
                selectedTab = firstMatch
            }
        }
        .background {
            Group {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .glassEffect(
                            .clear
                                .tint(Color.white.opacity(0.1))
                                .interactive(),
                            in: .rect(cornerRadius: 18)
                        )
                } else {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private var resolvedSelection: SettingsTab {
        availableTabs.contains(selectedTab) ? selectedTab : (availableTabs.first ?? .general)
    }

    @ToolbarContentBuilder
    private var toolbarSpacingShim: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                toolbarSpacerView
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                toolbarSpacerView
            }
        }
    }

    @ViewBuilder
    private var toolbarSpacerView: some View {
        Color.clear
            .frame(width: 96, height: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var filteredTabs: [SettingsTab] {
        tabsMatchingSearch(searchText)
    }

    private var selectionBinding: Binding<SettingsTab> {
        Binding(
            get: { resolvedSelection },
            set: { newValue in
                selectedTab = newValue
            }
        )
    }

    @ViewBuilder
    private func sidebarIcon(for tab: SettingsTab) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tab.tint.opacity(1),
                        tab.tint.opacity(0.7)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.7)
                    .blendMode(.plusLighter)
            }
            .shadow(color: tab.tint.opacity(0.35), radius: 2, x: 0, y: 1)
            .overlay {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
    }

    @ViewBuilder
    private func sidebarRow(for tab: SettingsTab) -> some View {
        HStack(spacing: 10) {
            sidebarIcon(for: tab)
            Text(LocalizedStringKey(tab.title))
            if tab == .downloads {
                Spacer()
                Text("BETA")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private var availableTabs: [SettingsTab] {
        // Ordered to match group layout: core → media & display → system →
        // productivity → utilities → developer → integrations → info.
        let ordered: [SettingsTab] = [
            // Core
            .general,
            .appearance,
            // Media & Display
            .media,
            .liveActivities,
            .lockScreen,
            .devices,
            // System
            .hudAndOSD,
            .battery,
            // Productivity
            // Utilities
            .shelf,
            .downloads,
            .shortcuts,
            // Developer
            // Info
            .about
        ]

        return ordered.filter { isTabVisible($0) }
    }

    /// Groups the filtered tabs into sidebar sections, preserving both
    /// the group order and the per-group tab order from `availableTabs`.
    private var groupedFilteredTabs: [(group: SettingsTabGroup, tabs: [SettingsTab])] {
        let visible = filteredTabs
        var result: [(group: SettingsTabGroup, tabs: [SettingsTab])] = []

        for group in SettingsTabGroup.allCases {
            let tabs = visible.filter { $0.group == group }
            if !tabs.isEmpty {
                result.append((group: group, tabs: tabs))
            }
        }

        return result
    }

    private func tabsMatchingSearch(_ query: String) -> [SettingsTab] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return availableTabs }

        let entryMatches = searchEntries(matching: trimmed)
        let matchingTabs = Set(entryMatches.map(\.tab))

        return availableTabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(trimmed) || matchingTabs.contains(tab)
        }
    }

    private var searchSuggestions: [SettingsSearchEntry] {
        Array(searchEntries(matching: searchText).filter { $0.tab != .downloads }.prefix(8))
    }

    private func handleSearchSuggestionSelection(_ suggestion: SettingsSearchEntry) {
        guard suggestion.tab != .downloads else { return }
        highlightCoordinator.focus(on: suggestion)
        selectedTab = suggestion.tab
    }

    private struct SettingsSidebarSearchBar: View {
        @Binding var text: String
        let suggestions: [SettingsSearchEntry]
        let onSuggestionSelected: (SettingsSearchEntry) -> Void

        @FocusState private var isFocused: Bool
        @State private var hoveredSuggestionID: SettingsSearchEntry.ID?

        var body: some View {
            VStack(spacing: 6) {
                searchField
                if showSuggestions {
                    suggestionList
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSuggestions)
        }

        private var showSuggestions: Bool {
            isFocused && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !suggestions.isEmpty
        }

        private var searchField: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.secondary)

                TextField("Search Settings", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(triggerFirstSuggestion)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08))
            )
        }

        private var suggestionList: some View {
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        selectSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(suggestion.tab.tint)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: suggestion.tab.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.white)
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(suggestion.title))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                Text(LocalizedStringKey(suggestion.tab.title))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background(rowBackground(for: suggestion))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredSuggestionID = hovering ? suggestion.id : (hoveredSuggestionID == suggestion.id ? nil : hoveredSuggestionID)
                    }

                    if suggestion.id != suggestions.last?.id {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08))
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        private func rowBackground(for suggestion: SettingsSearchEntry) -> some View {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hoveredSuggestionID == suggestion.id ? Color.white.opacity(0.08) : Color.clear)
        }

        private func selectSuggestion(_ suggestion: SettingsSearchEntry) {
            onSuggestionSelected(suggestion)
            isFocused = false
        }

        private func triggerFirstSuggestion() {
            guard let first = suggestions.first else { return }
            selectSuggestion(first)
        }
    }

    private func searchEntries(matching query: String) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return settingsSearchIndex
            .filter { availableTabs.contains($0.tab) }
            .filter { entry in
                entry.title.localizedCaseInsensitiveContains(trimmed) ||
                entry.keywords.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
    }

    private var settingsSearchIndex: [SettingsSearchEntry] {
        [
            // General
            SettingsSearchEntry(tab: .general, title: "Enable Minimalistic UI", keywords: ["minimalistic", "ui mode", "general"], highlightID: SettingsTab.general.highlightID(for: "Enable Minimalistic UI")),
            SettingsSearchEntry(tab: .general, title: "Menubar icon", keywords: ["menu bar", "status bar", "icon"], highlightID: SettingsTab.general.highlightID(for: "Menubar icon")),
            SettingsSearchEntry(tab: .general, title: "Launch at login", keywords: ["autostart", "startup"], highlightID: SettingsTab.general.highlightID(for: "Launch at login")),
            SettingsSearchEntry(tab: .general, title: "Show on all displays", keywords: ["multi-display", "external monitor"], highlightID: SettingsTab.general.highlightID(for: "Show on all displays")),
            SettingsSearchEntry(tab: .general, title: "Show on a specific display", keywords: ["preferred screen", "display picker"], highlightID: SettingsTab.general.highlightID(for: "Show on a specific display")),
            SettingsSearchEntry(tab: .general, title: "Automatically switch displays", keywords: ["auto switch", "displays"], highlightID: SettingsTab.general.highlightID(for: "Automatically switch displays")),
            SettingsSearchEntry(tab: .general, title: "Hide Dynamic Island during screenshots & recordings", keywords: ["privacy", "screenshot", "recording"], highlightID: SettingsTab.general.highlightID(for: "Hide Dynamic Island during screenshots & recordings")),
            SettingsSearchEntry(tab: .general, title: "Extend hover area", keywords: ["hover", "cursor"], highlightID: SettingsTab.general.highlightID(for: "Extend hover area")),
            SettingsSearchEntry(tab: .general, title: "Enable haptics", keywords: ["haptic", "feedback"], highlightID: SettingsTab.general.highlightID(for: "Enable haptics")),
            SettingsSearchEntry(tab: .general, title: "Open notch on hover", keywords: ["hover to open", "auto open"], highlightID: SettingsTab.general.highlightID(for: "Open notch on hover")),
            SettingsSearchEntry(tab: .general, title: "External display style", keywords: ["dynamic island", "pill", "external display", "non-notch", "floating", "capsule"], highlightID: SettingsTab.general.highlightID(for: "External display style")),
            SettingsSearchEntry(tab: .general, title: "Hide until hovered", keywords: ["hide", "hover", "external", "non-notch", "auto hide", "slide"], highlightID: SettingsTab.general.highlightID(for: "Hide until hovered")),
            SettingsSearchEntry(tab: .general, title: "Notch display height", keywords: ["display height", "menu bar size"], highlightID: SettingsTab.general.highlightID(for: "Notch display height")),

            // Live Activities
            SettingsSearchEntry(tab: .liveActivities, title: "Enable Screen Recording Detection", keywords: ["screen recording", "indicator"], highlightID: SettingsTab.liveActivities.highlightID(for: "Enable Screen Recording Detection")),
            SettingsSearchEntry(tab: .liveActivities, title: "Show Recording Indicator", keywords: ["recording indicator", "red dot"], highlightID: SettingsTab.liveActivities.highlightID(for: "Show Recording Indicator")),
            SettingsSearchEntry(tab: .liveActivities, title: "Enable Focus Detection", keywords: ["focus", "do not disturb", "dnd"], highlightID: SettingsTab.liveActivities.highlightID(for: "Enable Focus Detection")),
            SettingsSearchEntry(tab: .liveActivities, title: "Show Focus Indicator", keywords: ["focus icon", "moon"], highlightID: SettingsTab.liveActivities.highlightID(for: "Show Focus Indicator")),
            SettingsSearchEntry(tab: .liveActivities, title: "Show Focus Label", keywords: ["focus label", "text"], highlightID: SettingsTab.liveActivities.highlightID(for: "Show Focus Label")),
            SettingsSearchEntry(tab: .liveActivities, title: "Enable Camera Detection", keywords: ["camera", "privacy indicator"], highlightID: SettingsTab.liveActivities.highlightID(for: "Enable Camera Detection")),
            SettingsSearchEntry(tab: .liveActivities, title: "Enable Microphone Detection", keywords: ["microphone", "privacy"], highlightID: SettingsTab.liveActivities.highlightID(for: "Enable Microphone Detection")),
            SettingsSearchEntry(tab: .liveActivities, title: "Enable music live activity", keywords: ["music", "now playing"], highlightID: SettingsTab.liveActivities.highlightID(for: "Enable music live activity")),

            // Battery (Charge)
            SettingsSearchEntry(tab: .battery, title: "Show battery indicator", keywords: ["battery hud", "charge"], highlightID: SettingsTab.battery.highlightID(for: "Show battery indicator")),
            SettingsSearchEntry(tab: .battery, title: "Show battery percentage", keywords: ["battery percent"], highlightID: SettingsTab.battery.highlightID(for: "Show battery percentage")),
            SettingsSearchEntry(tab: .battery, title: "Show power status notifications", keywords: ["notifications", "power"], highlightID: SettingsTab.battery.highlightID(for: "Show power status notifications")),
            SettingsSearchEntry(tab: .battery, title: "Show power status icons", keywords: ["power icons", "charging icon"], highlightID: SettingsTab.battery.highlightID(for: "Show power status icons")),
            SettingsSearchEntry(tab: .battery, title: "Play low battery alert sound", keywords: ["low battery", "alert", "sound"], highlightID: SettingsTab.battery.highlightID(for: "Play low battery alert sound")),
            SettingsSearchEntry(tab: .battery, title: "Charging HUD", keywords: ["battery", "charging", "temporary activity"], highlightID: SettingsTab.battery.highlightID(for: "Charging HUD")),
            SettingsSearchEntry(tab: .battery, title: "Low battery HUD", keywords: ["battery", "low", "temporary activity"], highlightID: SettingsTab.battery.highlightID(for: "Low battery HUD")),
            SettingsSearchEntry(tab: .battery, title: "Fully charged HUD", keywords: ["battery", "full", "temporary activity"], highlightID: SettingsTab.battery.highlightID(for: "Fully charged HUD")),
            SettingsSearchEntry(tab: .battery, title: "Charging duration", keywords: ["charging", "duration", "seconds"], highlightID: SettingsTab.battery.highlightID(for: "Charging duration")),
            SettingsSearchEntry(tab: .battery, title: "Low battery duration", keywords: ["low battery", "duration", "seconds"], highlightID: SettingsTab.battery.highlightID(for: "Low battery duration")),
            SettingsSearchEntry(tab: .battery, title: "Full battery duration", keywords: ["full battery", "duration", "seconds"], highlightID: SettingsTab.battery.highlightID(for: "Full battery duration")),
            SettingsSearchEntry(tab: .battery, title: "Test charging HUD", keywords: ["battery", "test", "charging", "preview"], highlightID: nil),
            SettingsSearchEntry(tab: .battery, title: "Test low battery HUD", keywords: ["battery", "test", "low", "preview"], highlightID: nil),
            SettingsSearchEntry(tab: .battery, title: "Test full battery HUD", keywords: ["battery", "test", "full", "preview"], highlightID: nil),
            SettingsSearchEntry(tab: .battery, title: "Low battery style", keywords: ["battery", "style", "compact", "standard"], highlightID: SettingsTab.battery.highlightID(for: "Low battery style")),
            SettingsSearchEntry(tab: .battery, title: "Low battery threshold", keywords: ["battery", "threshold", "percent"], highlightID: SettingsTab.battery.highlightID(for: "Low battery threshold")),
            SettingsSearchEntry(tab: .battery, title: "Full battery style", keywords: ["battery", "style", "compact", "standard"], highlightID: SettingsTab.battery.highlightID(for: "Full battery style")),
            SettingsSearchEntry(tab: .battery, title: "Full charge threshold", keywords: ["battery", "threshold", "full"], highlightID: SettingsTab.battery.highlightID(for: "Full charge threshold")),

            // HUDs
            SettingsSearchEntry(tab: .devices, title: "Show Bluetooth device connections", keywords: ["bluetooth", "hud"], highlightID: SettingsTab.devices.highlightID(for: "Show Bluetooth device connections")),
            SettingsSearchEntry(tab: .devices, title: "Use circular battery indicator", keywords: ["battery", "circular"], highlightID: SettingsTab.devices.highlightID(for: "Use circular battery indicator")),
            SettingsSearchEntry(tab: .devices, title: "Show battery percentage text in HUD", keywords: ["battery text"], highlightID: SettingsTab.devices.highlightID(for: "Show battery percentage text in HUD")),
            SettingsSearchEntry(tab: .devices, title: "Scroll device name in HUD", keywords: ["marquee", "device name"], highlightID: SettingsTab.devices.highlightID(for: "Scroll device name in HUD")),
            SettingsSearchEntry(tab: .devices, title: "Use 3D Bluetooth HUD icon", keywords: ["bluetooth", "3d", "animation", "mov"], highlightID: SettingsTab.devices.highlightID(for: "Use 3D Bluetooth HUD icon")),
            SettingsSearchEntry(tab: .devices, title: "Color-coded battery display", keywords: ["color", "battery"], highlightID: SettingsTab.devices.highlightID(for: "Color-coded battery display")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Color-coded volume display", keywords: ["volume", "color"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Color-coded volume display")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Smooth color transitions", keywords: ["gradient", "smooth"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Smooth color transitions")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Show percentages beside progress bars", keywords: ["percentages", "progress"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Show percentages beside progress bars")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "HUD style", keywords: ["inline", "compact"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "HUD style")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Progressbar style", keywords: ["progress", "style"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Progressbar style")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Enable glowing effect", keywords: ["glow", "indicator"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Enable glowing effect")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Use accent color", keywords: ["accent", "color"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Use accent color")),

            // Custom OSD
            SettingsSearchEntry(tab: .hudAndOSD, title: "Enable Custom OSD", keywords: ["osd", "on-screen display", "custom osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Enable Custom OSD")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Volume OSD", keywords: ["volume", "osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Volume OSD")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Brightness OSD", keywords: ["brightness", "osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Brightness OSD")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Keyboard Backlight OSD", keywords: ["keyboard", "backlight", "osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Keyboard Backlight OSD")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Material", keywords: ["material", "frosted", "liquid", "glass", "solid", "osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Material")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Icon & Progress Color", keywords: ["color", "icon", "white", "black", "gray", "osd"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Icon & Progress Color")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Volume step", keywords: ["volume", "step", "percent"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Volume step")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Volume fine step", keywords: ["volume", "fine", "step", "percent"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Volume fine step")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Brightness step", keywords: ["brightness", "step", "percent"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Brightness step")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Brightness fine step", keywords: ["brightness", "fine", "step", "percent"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Brightness fine step")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Third-party DDC app integration", keywords: ["ddc", "third party", "external", "display", "betterdisplay", "lunar"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Third-party DDC app integration")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Third-party DDC provider", keywords: ["provider", "betterdisplay", "lunar", "integration", "refresh detection"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Third-party DDC provider")),
            SettingsSearchEntry(tab: .hudAndOSD, title: "Enable external volume control listener", keywords: ["external volume", "ddc volume", "betterdisplay volume", "lunar volume", "disable native volume"], highlightID: SettingsTab.hudAndOSD.highlightID(for: "Enable external volume control listener")),

            // Media
            SettingsSearchEntry(tab: .media, title: "Music Source", keywords: ["media source", "controller"], highlightID: SettingsTab.media.highlightID(for: "Music Source")),
            SettingsSearchEntry(tab: .media, title: "Skip buttons", keywords: ["skip", "controls", "±10"], highlightID: SettingsTab.media.highlightID(for: "Skip buttons")),
            SettingsSearchEntry(tab: .media, title: "Sneak Peek Style", keywords: ["sneak peek", "preview"], highlightID: SettingsTab.media.highlightID(for: "Sneak Peek Style")),
            SettingsSearchEntry(tab: .media, title: "Enable lyrics", keywords: ["lyrics", "song text"], highlightID: SettingsTab.media.highlightID(for: "Enable lyrics")),
            SettingsSearchEntry(tab: .media, title: "Show live canvas in Dynamic Island", keywords: ["canvas", "live canvas", "album art", "dynamic island", "spotify canvas"], highlightID: SettingsTab.media.highlightID(for: "Show live canvas in Dynamic Island")),
            SettingsSearchEntry(tab: .media, title: "Auto-hide inactive notch media player", keywords: ["auto hide", "inactive", "placeholder", "notch media"], highlightID: SettingsTab.media.highlightID(for: "Auto-hide inactive notch media player")),
            SettingsSearchEntry(tab: .media, title: "Show Change Media Output control", keywords: ["airplay", "route picker", "media output"], highlightID: SettingsTab.media.highlightID(for: "Show Change Media Output control")),
            SettingsSearchEntry(tab: .media, title: "Enable album art parallax", keywords: ["parallax", "lock screen", "album art"], highlightID: SettingsTab.media.highlightID(for: "Enable album art parallax")),
            SettingsSearchEntry(tab: .media, title: "Enable album art parallax effect", keywords: ["parallax", "parallax effect", "album art"], highlightID: SettingsTab.media.highlightID(for: "Enable album art parallax effect")),

            // Shelf
            SettingsSearchEntry(tab: .shelf, title: "Enable shelf", keywords: ["shelf", "dock"], highlightID: SettingsTab.shelf.highlightID(for: "Enable shelf")),
            SettingsSearchEntry(tab: .shelf, title: "Open shelf tab by default if items added", keywords: ["auto open", "shelf tab"], highlightID: SettingsTab.shelf.highlightID(for: "Open shelf tab by default if items added")),
            SettingsSearchEntry(tab: .shelf, title: "Expanded drag detection area", keywords: ["shelf", "drag"], highlightID: SettingsTab.shelf.highlightID(for: "Expanded drag detection area")),
            SettingsSearchEntry(tab: .shelf, title: "Copy items on drag", keywords: ["shelf", "drag", "copy"], highlightID: SettingsTab.shelf.highlightID(for: "Copy items on drag")),
            SettingsSearchEntry(tab: .shelf, title: "Remove from shelf after dragging", keywords: ["shelf", "drag", "remove"], highlightID: SettingsTab.shelf.highlightID(for: "Remove from shelf after dragging")),
            SettingsSearchEntry(tab: .shelf, title: "Quick Share Service", keywords: ["shelf", "share", "airdrop", "localsend"], highlightID: SettingsTab.shelf.highlightID(for: "Quick Share Service")),
            SettingsSearchEntry(tab: .shelf, title: "LocalSend Device Picker Style", keywords: ["localsend", "glass", "picker", "material"], highlightID: SettingsTab.shelf.highlightID(for: "Device Picker Style")),

            // Appearance
            SettingsSearchEntry(tab: .appearance, title: "Main screen style", keywords: ["dynamic island", "pill", "non-notch", "display style", "notch style"], highlightID: SettingsTab.appearance.highlightID(for: "Main screen style")),
            SettingsSearchEntry(tab: .appearance, title: "Settings icon in notch", keywords: ["settings button", "toolbar"], highlightID: SettingsTab.appearance.highlightID(for: "Settings icon in notch")),
            SettingsSearchEntry(tab: .appearance, title: "Enable window shadow", keywords: ["shadow", "appearance"], highlightID: SettingsTab.appearance.highlightID(for: "Enable window shadow")),
            SettingsSearchEntry(tab: .appearance, title: "Corner radius scaling", keywords: ["corner radius", "shape"], highlightID: SettingsTab.appearance.highlightID(for: "Corner radius scaling")),
            SettingsSearchEntry(tab: .appearance, title: "Use simpler close animation", keywords: ["close animation", "notch"], highlightID: SettingsTab.appearance.highlightID(for: "Use simpler close animation")),
            SettingsSearchEntry(tab: .appearance, title: "Notch Width", keywords: ["expanded notch", "width", "resize"], highlightID: SettingsTab.appearance.highlightID(for: "Expanded notch width")),
            SettingsSearchEntry(tab: .appearance, title: "Enable colored spectrograms", keywords: ["spectrogram", "audio"], highlightID: SettingsTab.appearance.highlightID(for: "Enable colored spectrograms")),
            SettingsSearchEntry(tab: .appearance, title: "Enable blur effect behind album art", keywords: ["blur", "album art"], highlightID: SettingsTab.appearance.highlightID(for: "Enable blur effect behind album art")),
            SettingsSearchEntry(tab: .appearance, title: "Slider color", keywords: ["slider", "accent"], highlightID: SettingsTab.appearance.highlightID(for: "Slider color")),
            SettingsSearchEntry(tab: .appearance, title: "Enable Dynamic mirror", keywords: ["mirror", "reflection"], highlightID: SettingsTab.appearance.highlightID(for: "Enable Dynamic mirror")),
            SettingsSearchEntry(tab: .appearance, title: "Mirror shape", keywords: ["mirror shape", "circle", "rectangle"], highlightID: SettingsTab.appearance.highlightID(for: "Mirror shape")),
            SettingsSearchEntry(tab: .appearance, title: "Idle Animation", keywords: ["face animation", "idle", "cool face"], highlightID: SettingsTab.appearance.highlightID(for: "Idle Animation")),
            SettingsSearchEntry(tab: .appearance, title: "App icon", keywords: ["app icon", "custom icon"], highlightID: SettingsTab.appearance.highlightID(for: "App icon")),

            // Lock Screen
            SettingsSearchEntry(tab: .lockScreen, title: "Enable lock screen live activity", keywords: ["lock screen", "live activity"], highlightID: SettingsTab.lockScreen.highlightID(for: "Enable lock screen live activity")),
            SettingsSearchEntry(tab: .lockScreen, title: "Play lock/unlock sounds", keywords: ["chime", "sound"], highlightID: SettingsTab.lockScreen.highlightID(for: "Play lock/unlock sounds")),
            SettingsSearchEntry(tab: .lockScreen, title: "Material", keywords: ["glass", "frosted", "liquid"], highlightID: SettingsTab.lockScreen.highlightID(for: "Material")),
            SettingsSearchEntry(tab: .lockScreen, title: "Show lock screen media panel", keywords: ["media panel", "lock screen media"], highlightID: SettingsTab.lockScreen.highlightID(for: "Show lock screen media panel")),
            SettingsSearchEntry(tab: .lockScreen, title: "Show media app icon", keywords: ["app icon", "media"], highlightID: SettingsTab.lockScreen.highlightID(for: "Show media app icon")),
            SettingsSearchEntry(tab: .lockScreen, title: "Show panel border", keywords: ["panel border"], highlightID: SettingsTab.lockScreen.highlightID(for: "Show panel border")),
            SettingsSearchEntry(tab: .lockScreen, title: "Enable media panel blur", keywords: ["blur", "media panel"], highlightID: SettingsTab.lockScreen.highlightID(for: "Enable media panel blur")),

            // Shortcuts
            SettingsSearchEntry(tab: .shortcuts, title: "Enable global keyboard shortcuts", keywords: ["keyboard", "shortcut"], highlightID: SettingsTab.shortcuts.highlightID(for: "Enable global keyboard shortcuts")),

        ]
    }

    private func isTabVisible(_ tab: SettingsTab) -> Bool {
        switch tab {
        case .shelf:
            return !enableMinimalisticUI
        default:
            return true
        }
    }

    @ViewBuilder
    private func detailView(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            SettingsForm(tab: .general) {
                GeneralSettings()
            }
        case .liveActivities:
            SettingsForm(tab: .liveActivities) {
                LiveActivitiesSettings()
            }
        case .appearance:
            SettingsForm(tab: .appearance) {
                Appearance()
            }
        case .lockScreen:
            SettingsForm(tab: .lockScreen) {
                LockScreenSettings()
            }
        case .media:
            SettingsForm(tab: .media) {
                Media()
            }
        case .devices:
            SettingsForm(tab: .devices) {
                DevicesSettingsView()
            }
        case .hudAndOSD:
            SettingsForm(tab: .hudAndOSD) {
                HUDAndOSDSettingsView()
            }
        case .battery:
            SettingsForm(tab: .battery) {
                Charge()
            }
        case .downloads:
            SettingsForm(tab: .downloads) {
                Downloads()
            }
        case .shelf:
            SettingsForm(tab: .shelf) {
                Shelf()
            }
        case .shortcuts:
            SettingsForm(tab: .shortcuts) {
                Shortcuts()
            }
        case .about:
            SettingsForm(tab: .about) {
                About()
            }
        }
    }
}

struct GeneralSettings: View {
    @State private var screens: [String] = NSScreen.screens.compactMap { $0.localizedName }
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @Default(.mirrorShape) var mirrorShape
    @Default(.showEmojis) var showEmojis
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.closedNotchWidth) var closedNotchWidth
    @Default(.customizePhysicalNotchWidth) var customizePhysicalNotchWidth
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.showMinimalisticBatteryIndicator) var showMinimalisticBatteryIndicator
    @Default(.externalDisplayStyle) var externalDisplayStyle
    @Default(.hideNonNotchUntilHover) var hideNonNotchUntilHover

    private func highlightID(_ title: String) -> String {
        SettingsTab.general.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableMinimalisticUI) {
                    Text("Enable Minimalistic UI")
                }
                .onChange(of: enableMinimalisticUI) { _, newValue in
                    if newValue {
                        // Auto-enable simpler animation mode
                        Defaults[.useModernCloseAnimation] = true
                    }
                }
                .settingsHighlight(id: highlightID("Enable Minimalistic UI"))

                Defaults.Toggle(key: .showMinimalisticBatteryIndicator) {
                    Text("Show battery indicator")
                }
                .disabled(!enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Show battery indicator in Minimalistic UI"))

                Defaults.Toggle(key: .showBatteryPercentInside) {
                    Text("Show battery percentage inside icon")
                }
                .disabled(!enableMinimalisticUI || !Defaults[.showMinimalisticBatteryIndicator])
                .settingsHighlight(id: highlightID("Show battery percentage inside icon"))
            } header: {
                Text("UI Mode")
            } footer: {
                Text("Minimalistic mode focuses on media controls and system HUDs, hiding all extra features for a clean, focused experience. Automatically enables simpler animations.")
            }

            Section {
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Menubar icon")
                }
                .settingsHighlight(id: highlightID("Menubar icon"))
                LaunchAtLogin.Toggle {
                    Text("Launch at login")
                }
                .settingsHighlight(id: highlightID("Launch at login"))
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                .settingsHighlight(id: highlightID("Show on all displays"))
                Picker("Show on a specific display", selection: $coordinator.preferredScreen) {
                    ForEach(screens, id: \.self) { screen in
                        Text(screen)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens =  NSScreen.screens.compactMap({$0.localizedName})
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: highlightID("Show on a specific display"))
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                .onChange(of: automaticallySwitchDisplay) {
                    NotificationCenter.default.post(name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: highlightID("Automatically switch displays"))
                Defaults.Toggle(key: .hideDynamicIslandFromScreenCapture) {
                    Text("Hide Dynamic Island during screenshots & recordings")
                }
                .settingsHighlight(id: highlightID("Hide Dynamic Island during screenshots & recordings"))
            } header: {
                Text("System features")
            }

            Section {
                Picker(selection: $notchHeightMode, label:
                        Text("Notch display height")) {
                    Text("Match real notch size")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                        .onChange(of: notchHeightMode) {
                            switch notchHeightMode {
                            case .matchRealNotchSize:
                                notchHeight = 38
                            case .matchMenuBar:
                                notchHeight = 44
                            case .custom:
                                notchHeight = 38
                            }
                            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                        }
                        .settingsHighlight(id: highlightID("Notch display height"))
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Non-notch display height", selection: $nonNotchHeightMode) {
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Match real notch size")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar:
                        nonNotchHeight = 24
                    case .matchRealNotchSize:
                        nonNotchHeight = 32
                    case .custom:
                        nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch Height")
            }

            NotchBehaviour()

        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .navigationTitle("General")
    }


    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .extendHoverArea) {
                Text("Extend hover area")
            }
            .settingsHighlight(id: highlightID("Extend hover area"))
            Defaults.Toggle(key: .enableHaptics) {
                Text("Enable haptics")
            }
            .settingsHighlight(id: highlightID("Enable haptics"))
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            .settingsHighlight(id: highlightID("Open notch on hover"))
            Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Minimum hover duration")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
            }
            Picker("External display style", selection: $externalDisplayStyle) {
                ForEach(ExternalDisplayStyle.allCases) { style in
                    Text(style.localizedName)
                        .tag(style)
                }
            }
            .onChange(of: externalDisplayStyle) {
                NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
            }
            .settingsHighlight(id: highlightID("External display style"))
            Text(externalDisplayStyle.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Defaults.Toggle(key: .hideNonNotchUntilHover) {
                Text("Hide until hovered on non-notch displays")
            }
            .settingsHighlight(id: highlightID("Hide until hovered"))
            Text("When enabled, the notch slides up and hides on external (non-notch) displays until you hover over it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Notch behavior")
        }
    }
}

struct Charge: View {
    @ObservedObject private var batteryStatusViewModel = BatteryStatusViewModel.shared
    @Default(.showPowerStatusNotifications) private var showPowerStatusNotifications
    @Default(.showChargingBatteryHUD) private var showChargingBatteryHUD
    @Default(.showLowBatteryHUD) private var showLowBatteryHUD
    @Default(.showFullBatteryHUD) private var showFullBatteryHUD
    @Default(.chargingBatteryHUDDuration) private var chargingBatteryHUDDuration
    @Default(.lowBatteryHUDDuration) private var lowBatteryHUDDuration
    @Default(.fullBatteryHUDDuration) private var fullBatteryHUDDuration
    @Default(.lowBatteryHUDThreshold) private var lowBatteryHUDThreshold
    @Default(.fullBatteryHUDThreshold) private var fullBatteryHUDThreshold
    @Default(.lowBatteryHUDStyle) private var lowBatteryHUDStyle
    @Default(.fullBatteryHUDStyle) private var fullBatteryHUDStyle

    private func highlightID(_ title: String) -> String {
        SettingsTab.battery.highlightID(for: title)
    }

    private var chargingDurationBinding: Binding<Double> {
        Binding(
            get: { Double(chargingBatteryHUDDuration) },
            set: { chargingBatteryHUDDuration = Int($0.rounded()) }
        )
    }

    private var lowBatteryDurationBinding: Binding<Double> {
        Binding(
            get: { Double(lowBatteryHUDDuration) },
            set: { lowBatteryHUDDuration = Int($0.rounded()) }
        )
    }

    private var fullBatteryDurationBinding: Binding<Double> {
        Binding(
            get: { Double(fullBatteryHUDDuration) },
            set: { fullBatteryHUDDuration = Int($0.rounded()) }
        )
    }

    private var lowBatteryThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(lowBatteryHUDThreshold) },
            set: { lowBatteryHUDThreshold = Int($0.rounded()) }
        )
    }

    private var fullBatteryThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(fullBatteryHUDThreshold) },
            set: { fullBatteryHUDThreshold = Int($0.rounded()) }
        )
    }

    private func sectionOpacity(_ isEnabled: Bool) -> Double {
        isEnabled ? 1 : 0.5
    }

    var body: some View {
        Form {
            if BatteryActivityManager.shared.hasBattery() {
                Section {
                    Defaults.Toggle(key: .showBatteryIndicator) {
                        Text("Show battery indicator")
                    }
                    .settingsHighlight(id: highlightID("Show battery indicator"))
                    Defaults.Toggle(key: .showPowerStatusNotifications) {
                        Text("Show power status notifications")
                    }
                    .settingsHighlight(id: highlightID("Show power status notifications"))
                    Defaults.Toggle(key: .playLowBatteryAlertSound) {
                        Text("Play low battery alert sound")
                    }
                    .settingsHighlight(id: highlightID("Play low battery alert sound"))
                } header: {
                    Text("General")
                }
                Section {
                    Defaults.Toggle(key: .showBatteryPercentage) {
                        Text("Show battery percentage")
                    }
                    .settingsHighlight(id: highlightID("Show battery percentage"))
                    Defaults.Toggle(key: .showPowerStatusIcons) {
                        Text("Show power status icons")
                    }
                    .settingsHighlight(id: highlightID("Show power status icons"))
                } header: {
                    Text("Battery Information")
                }
                Section {
                    Defaults.Toggle(key: .showChargingBatteryHUD) {
                        Text("Charging HUD")
                    }
                    .settingsHighlight(id: highlightID("Charging HUD"))

                    Defaults.Toggle(key: .showLowBatteryHUD) {
                        Text("Low battery HUD")
                    }
                    .settingsHighlight(id: highlightID("Low battery HUD"))

                    Defaults.Toggle(key: .showFullBatteryHUD) {
                        Text("Fully charged HUD")
                    }
                    .settingsHighlight(id: highlightID("Fully charged HUD"))
                } header: {
                    Text("Battery HUDs")
                } footer: {
                    Text("These temporary HUDs recreate the charging, low-battery, and full-battery notch alerts.")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Charging duration")
                            Spacer()
                            Text("\(chargingBatteryHUDDuration)s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: chargingDurationBinding, in: 1...10, step: 1)
                    }
                    .settingsHighlight(id: highlightID("Charging duration"))
                    .disabled(!showPowerStatusNotifications || !showChargingBatteryHUD)
                    .opacity(sectionOpacity(showPowerStatusNotifications && showChargingBatteryHUD))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Low battery duration")
                            Spacer()
                            Text("\(lowBatteryHUDDuration)s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: lowBatteryDurationBinding, in: 1...10, step: 1)
                    }
                    .settingsHighlight(id: highlightID("Low battery duration"))
                    .disabled(!showPowerStatusNotifications || !showLowBatteryHUD)
                    .opacity(sectionOpacity(showPowerStatusNotifications && showLowBatteryHUD))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Full battery duration")
                            Spacer()
                            Text("\(fullBatteryHUDDuration)s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: fullBatteryDurationBinding, in: 1...10, step: 1)
                    }
                    .settingsHighlight(id: highlightID("Full battery duration"))
                    .disabled(!showPowerStatusNotifications || !showFullBatteryHUD)
                    .opacity(sectionOpacity(showPowerStatusNotifications && showFullBatteryHUD))
                } header: {
                    Text("HUD Duration")
                }
                Section {
                    Button {
                        batteryStatusViewModel.triggerTestHUD(kind: .charging)
                    } label: {
                        Label("Test charging HUD", systemImage: "bolt.fill")
                    }
                    .disabled(!showPowerStatusNotifications || !showChargingBatteryHUD)

                    Button {
                        batteryStatusViewModel.triggerTestHUD(kind: .lowBattery)
                    } label: {
                        Label("Test low battery HUD", systemImage: "battery.25")
                    }
                    .disabled(!showPowerStatusNotifications || !showLowBatteryHUD)

                    Button {
                        batteryStatusViewModel.triggerTestHUD(kind: .fullBattery)
                    } label: {
                        Label("Test full battery HUD", systemImage: "battery.100")
                    }
                    .disabled(!showPowerStatusNotifications || !showFullBatteryHUD)
                } header: {
                    Text("HUD Tests")
                } footer: {
                    Text("Runs the real notch animation on the current target display. If an external screen is using Dynamic Island mode, the battery HUD is sent there first.")
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Low battery style", selection: $lowBatteryHUDStyle) {
                            ForEach(BatteryNotificationStyle.allCases) { style in
                                Text(style.title)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Compact matches the charging HUD. Standard uses the expanded DynamicNotch-style card.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsHighlight(id: highlightID("Low battery style"))


                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Low battery threshold")
                            Spacer()
                            Text("\(lowBatteryHUDThreshold)%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: lowBatteryThresholdBinding, in: 5...30, step: 1)
                    }
                    .settingsHighlight(id: highlightID("Low battery threshold"))
                } header: {
                    Text("Low Battery")
                }
                .disabled(!showPowerStatusNotifications || !showLowBatteryHUD)
                .opacity(sectionOpacity(showPowerStatusNotifications && showLowBatteryHUD))

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Full battery style", selection: $fullBatteryHUDStyle) {
                            ForEach(BatteryNotificationStyle.allCases) { style in
                                Text(style.title)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Compact keeps the alert inline. Standard uses the taller full-charge HUD with the charging animation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsHighlight(id: highlightID("Full battery style"))


                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Full charge threshold")
                            Spacer()
                            Text("\(fullBatteryHUDThreshold)%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: fullBatteryThresholdBinding, in: 80...100, step: 1)
                    }
                    .settingsHighlight(id: highlightID("Full charge threshold"))
                } header: {
                    Text("Full Battery")
                }
                .disabled(!showPowerStatusNotifications || !showFullBatteryHUD)
                .opacity(sectionOpacity(showPowerStatusNotifications && showFullBatteryHUD))
            } else {
                ContentUnavailableView {
                    VStack(spacing: 16) {
                        Image(systemName: "battery.100percent.slash")
                            .font(.title)
                        Text("Battery settings and informations are only available on MacBooks")
                            .font(.title3)
                    }
                }
            }
        }
        .navigationTitle("Battery")
    }
}

struct Downloads: View {
    @Default(.selectedDownloadIndicatorStyle) var selectedDownloadIndicatorStyle
    @Default(.selectedDownloadIconStyle) var selectedDownloadIconStyle

    private func highlightID(_ title: String) -> String {
        SettingsTab.downloads.highlightID(for: title)
    }

    var body: some View {
        SwiftUI.Form {
            Section {
                Defaults.Toggle(key: .enableDownloadListener) {
                    Text("Enable download detection")
                }
                .settingsHighlight(id: highlightID("Enable download detection"))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Download indicator style")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    HStack(spacing: 16) {
                        DownloadStyleButton(
                            style: .progress,
                            isSelected: selectedDownloadIndicatorStyle == .progress,
                            disabled: !Defaults[.enableDownloadListener]
                        ) {
                            selectedDownloadIndicatorStyle = .progress
                        }

                        DownloadStyleButton(
                            style: .circle,
                            isSelected: selectedDownloadIndicatorStyle == .circle,
                            disabled: !Defaults[.enableDownloadListener]
                        ) {
                            selectedDownloadIndicatorStyle = .circle
                        }
                    }
                }
                .settingsHighlight(id: highlightID("Download indicator style"))
            } header: {
                Text("Download Detection")
            } footer: {
                Text("Monitor your Downloads folder for Chromium-style downloads (.crdownload files) and show a live activity in the Dynamic Island while downloads are in progress.")
            }
        }
        .navigationTitle("Downloads")
    }

    struct DownloadStyleButton: View {
        let style: DownloadIndicatorStyle
        let isSelected: Bool
        let disabled: Bool
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                        )

                    if style == .progress {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .frame(width: 40)
                    } else {
                        SpinningCircleDownloadView()
                    }
                }
                .frame(width: 80, height: 60)
                .onHover { hovering in
                    if !disabled {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHovering = hovering
                        }
                    }
                }

                Text(style.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 100)
                    .foregroundStyle(disabled ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !disabled {
                    action()
                }
            }
            .opacity(disabled ? 0.5 : 1.0)
        }

        private var backgroundColor: Color {
            if disabled { return Color(nsColor: .controlBackgroundColor) }
            if isSelected { return Color.accentColor.opacity(0.1) }
            if isHovering { return Color.primary.opacity(0.05) }
            return Color(nsColor: .controlBackgroundColor)
        }

        private var borderColor: Color {
            if isSelected { return Color.accentColor }
            if isHovering { return Color.primary.opacity(0.1) }
            return Color.clear
        }
    }
}

final class HUDPreviewViewModel: ObservableObject {
    @Published var level: Float = 0
    @Published var iconName: String = "speaker.wave.3.fill"

    private var cancellables = Set<AnyCancellable>()

    init() {
        setup()
    }

    private func setup() {
        // Ensure controllers are active
        SystemVolumeController.shared.start()
        SystemBrightnessController.shared.start()
        SystemKeyboardBacklightController.shared.start()

        // Initial state from volume
        let vol = SystemVolumeController.shared.currentVolume
        self.level = vol
        if vol <= 0.01 { self.iconName = "speaker.slash.fill" }
        else if vol < 0.33 { self.iconName = "speaker.wave.1.fill" }
        else if vol < 0.66 { self.iconName = "speaker.wave.2.fill" }
        else { self.iconName = "speaker.wave.3.fill" }

        // Listeners
        NotificationCenter.default.publisher(for: .systemVolumeDidChange)
            .compactMap { $0.userInfo }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                if let vol = info["value"] as? Float {
                    self.level = vol
                    if vol <= 0.01 { self.iconName = "speaker.slash.fill" }
                    else if vol < 0.33 { self.iconName = "speaker.wave.1.fill" }
                    else if vol < 0.66 { self.iconName = "speaker.wave.2.fill" }
                    else { self.iconName = "speaker.wave.3.fill" }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .systemBrightnessDidChange)
            .compactMap { $0.userInfo }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                if let val = info["value"] as? Float {
                    self.level = val
                    self.iconName = "sun.max.fill"
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .keyboardBacklightDidChange)
            .compactMap { $0.userInfo }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                if let val = info["value"] as? Float {
                    self.level = val
                    self.iconName = val > 0.5 ? "light.max" : "light.min"
                }
            }
            .store(in: &cancellables)
    }
}

private struct HUDAndOSDSettingsView: View {
    @State private var selectedTab: Tab = {
        if Defaults[.enableSystemHUD] { return .hud }
        if Defaults[.enableCustomOSD] { return .osd }
        if Defaults[.enableVerticalHUD] { return .vertical }
        if Defaults[.enableCircularHUD] { return .circular }
        return .hud
    }()
    @Default(.enableSystemHUD) var enableSystemHUD
    @Default(.enableCustomOSD) var enableCustomOSD
    @Default(.enableVerticalHUD) var enableVerticalHUD
    @Default(.enableCircularHUD) var enableCircularHUD
    @Default(.verticalHUDPosition) var verticalHUDPosition
    @Default(.enableVolumeHUD) var enableVolumeHUD
    @Default(.enableBrightnessHUD) var enableBrightnessHUD
    @Default(.enableKeyboardBacklightHUD) var enableKeyboardBacklightHUD
    @Default(.enableThirdPartyDDCIntegration) var enableThirdPartyDDCIntegration
    @Default(.verticalHUDShowValue) var verticalHUDShowValue
    @Default(.verticalHUDInteractive) var verticalHUDInteractive
    @Default(.verticalHUDHeight) var verticalHUDHeight
    @Default(.verticalHUDWidth) var verticalHUDWidth
    @Default(.verticalHUDPadding) var verticalHUDPadding
    @Default(.verticalHUDUseAccentColor) var verticalHUDUseAccentColor
    @Default(.verticalHUDMaterial) var verticalHUDMaterial
    @Default(.verticalHUDLiquidGlassCustomizationMode) var verticalHUDLiquidGlassCustomizationMode
    @Default(.verticalHUDLiquidGlassVariant) var verticalHUDLiquidGlassVariant

    // Circular HUD Props
    @Default(.circularHUDShowValue) var circularHUDShowValue
    @Default(.circularHUDSize) var circularHUDSize
    @Default(.circularHUDStrokeWidth) var circularHUDStrokeWidth
    @Default(.circularHUDUseAccentColor) var circularHUDUseAccentColor
    @StateObject private var previewModel = HUDPreviewViewModel()
    @ObservedObject private var accessibilityPermission = AccessibilityPermissionStore.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case hud = "Dynamic Island HUD"
        case osd = "Custom OSD"
        case vertical = "Vertical Bar"
        case circular = "Circular"

        var id: String { rawValue }
    }

    private var paneBackgroundColor: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var availableVerticalMaterials: [OSDMaterial] {
        if #available(macOS 26.0, *) {
            return OSDMaterial.allCases
        }
        return OSDMaterial.allCases.filter { $0 != .liquid }
    }

    private var verticalLiquidVariantBinding: Binding<Double> {
        Binding(
            get: { Double(verticalHUDLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                verticalHUDLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                HUDSelectionCard(
                    title: String(localized: "Dynamic Island"),
                    isSelected: selectedTab == .hud,
                    action: {
                        selectedTab = .hud
                        enableSystemHUD = true
                        enableCustomOSD = false
                        enableVerticalHUD = false
                        enableCircularHUD = false
                    }
                ) {
                    VStack {
                        Capsule()
                            .fill(Color.black)
                            .frame(width: 64, height: 20)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .overlay {
                                HStack(spacing: 6) {
                                    Image(systemName: previewModel.iconName)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 12)

                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(Color.white.opacity(0.2))
                                            .overlay(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color.white)
                                                    .frame(width: geo.size.width * CGFloat(previewModel.level))
                                                    .animation(.spring(response: 0.3), value: previewModel.level)
                                            }
                                    }
                                    .frame(height: 4)
                                }
                                .padding(.horizontal, 8)
                            }
                    }
                }

                HUDSelectionCard(
                    title: String(localized: "Custom OSD"),
                    isSelected: selectedTab == .osd,
                    action: {
                        selectedTab = .osd
                        enableCustomOSD = true
                        enableSystemHUD = false
                        enableVerticalHUD = false
                        enableCircularHUD = false
                    }
                ) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: previewModel.iconName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                                    .symbolRenderingMode(.hierarchical)
                                    .contentTransition(.symbolEffect(.replace))

                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.2))
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary)
                                                .frame(width: geo.size.width * CGFloat(previewModel.level))
                                                .animation(.spring(response: 0.3), value: previewModel.level)
                                        }
                                }
                                .frame(width: 36, height: 4)
                            }
                        }
                        .frame(width: 44, height: 44)
                }

                HUDSelectionCard(
                    title: String(localized: "Vertical Bar"),
                    isSelected: selectedTab == .vertical,
                    action: {
                        selectedTab = .vertical
                        enableVerticalHUD = true
                        enableSystemHUD = false
                        enableCustomOSD = false
                        enableCircularHUD = false
                    }
                ) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        .overlay {
                            VStack {
                                GeometryReader { geo in
                                    VStack {
                                        Spacer()
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.white)
                                            .frame(height: max(0, geo.size.height * CGFloat(previewModel.level)))
                                            .animation(.spring(response: 0.3), value: previewModel.level)
                                    }
                                }
                                .mask(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(.bottom, 2)

                                Image(systemName: previewModel.iconName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(previewModel.level > 0.15 ? .black : .secondary)
                                    .symbolRenderingMode(.hierarchical)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .padding(4)
                        }
                        .frame(width: 22, height: 54)
                }

                HUDSelectionCard(
                    title: String(localized: "Circular"),
                    isSelected: selectedTab == .circular,
                    action: {
                        selectedTab = .circular
                        enableCircularHUD = true
                        enableSystemHUD = false
                        enableCustomOSD = false
                        enableVerticalHUD = false
                    }
                ) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: CGFloat(previewModel.level))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.3), value: previewModel.level)
                        Image(systemName: previewModel.iconName)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.hierarchical)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .padding(.top, 8)

            switch selectedTab {
            case .hud:
                HUD()
            case .osd:
                if #available(macOS 15.0, *) {
                    CustomOSDSettings()
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)

                        Text("macOS 15 or later required")
                            .font(.headline)

                        Text("Custom OSD feature requires macOS 15 or later.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            case .vertical:
                Form {
                    if !accessibilityPermission.isAuthorized && !enableThirdPartyDDCIntegration {
                        Section {
                            SettingsPermissionCallout(
                                message: "Accessibility permission is needed to intercept system controls for the Vertical HUD.",
                                requestAction: {
                                    accessibilityPermission.requestAuthorizationPrompt()
                                },
                                openSettingsAction: {
                                    accessibilityPermission.openSystemSettings()
                                }
                            )
                        } header: {
                            Text("Accessibility")
                        }
                    }

                    if accessibilityPermission.isAuthorized || enableThirdPartyDDCIntegration {
                        Section {
                            Toggle("Volume HUD", isOn: $enableVolumeHUD)
                            Toggle("Brightness HUD", isOn: $enableBrightnessHUD)
                            Toggle("Keyboard Backlight HUD", isOn: $enableKeyboardBacklightHUD)
                                .disabled(enableThirdPartyDDCIntegration)
                                .help(enableThirdPartyDDCIntegration ? "Disabled while external display integration is active — brightness keys are handled by the external app." : "")
                        } header: {
                            Text("Controls")
                        } footer: {
                            Text("Choose which system controls should display HUD notifications.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    Section {
                        Toggle("Show Percentage", isOn: $verticalHUDShowValue)
                        Toggle("Use Accent Color", isOn: $verticalHUDUseAccentColor)
                        Toggle("Interactive (Drag to Change)", isOn: $verticalHUDInteractive)
                        Picker("Material", selection: $verticalHUDMaterial) {
                            ForEach(availableVerticalMaterials, id: \.self) { material in
                                Text(material.rawValue).tag(material)
                            }
                        }

                        if verticalHUDMaterial == .liquid {
                            if #available(macOS 26.0, *) {
                                Picker("Glass mode", selection: $verticalHUDLiquidGlassCustomizationMode) {
                                    ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if verticalHUDLiquidGlassCustomizationMode == .customLiquid {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Custom liquid variant")
                                            Spacer()
                                            Text("v\(verticalHUDLiquidGlassVariant.rawValue)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: verticalLiquidVariantBinding, in: liquidVariantRange, step: 1)
                                    }
                                }
                            } else {
                                Text("Custom Liquid is available on macOS 26 or later.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Defaults.Toggle(key: .useColorCodedVolumeDisplay) {
                            Text("Color-coded Volume")
                        }
                        if Defaults[.useColorCodedVolumeDisplay] {
                            Defaults.Toggle(key: .useSmoothColorGradient) {
                                Text("Smooth color transitions")
                            }
                        }
                    } header: {
                        Text("Behavior & Style")
                    }

                    Section {
                        Picker("HUD Position", selection: $verticalHUDPosition) {
                            Text("Left").tag("left")
                            Text("Right").tag("right")
                        }
                        .pickerStyle(.menu)

                        VStack(alignment: .leading) {
                            Text("Screen Padding: \(Int(verticalHUDPadding))px")
                            Slider(value: $verticalHUDPadding, in: 0...100, step: 4)
                        }
                    } header: {
                        Text("Position")
                    } footer: {
                        Text("Choose directly on which side of the screen the vertical bar appears.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Width: \(Int(verticalHUDWidth))px")
                            Slider(value: $verticalHUDWidth, in: 24...80, step: 2)
                        }
                        VStack(alignment: .leading) {
                            Text("Height: \(Int(verticalHUDHeight))px")
                            Slider(value: $verticalHUDHeight, in: 100...500, step: 10)
                        }
                        Button("Reset to Default") {
                            verticalHUDWidth = 36
                            verticalHUDHeight = 160
                            verticalHUDPadding = 24
                        }
                    } header: {
                        Text("Dimensions")
                    }
                }

            case .circular:
                Form {
                    if !accessibilityPermission.isAuthorized && !enableThirdPartyDDCIntegration {
                        Section {
                            SettingsPermissionCallout(
                                message: "Accessibility permission is needed to intercept system controls for the Circular HUD.",
                                requestAction: {
                                    accessibilityPermission.requestAuthorizationPrompt()
                                },
                                openSettingsAction: {
                                    accessibilityPermission.openSystemSettings()
                                }
                            )
                        } header: {
                            Text("Accessibility")
                        }
                    }

                    if accessibilityPermission.isAuthorized || enableThirdPartyDDCIntegration {
                        Section {
                            Toggle("Volume HUD", isOn: $enableVolumeHUD)
                            Toggle("Brightness HUD", isOn: $enableBrightnessHUD)
                            Toggle("Keyboard Backlight HUD", isOn: $enableKeyboardBacklightHUD)
                                .disabled(enableThirdPartyDDCIntegration)
                                .help(enableThirdPartyDDCIntegration ? "Disabled while external display integration is active — brightness keys are handled by the external app." : "")
                        } header: {
                            Text("Controls")
                        } footer: {
                            Text("Choose which system controls should display HUD notifications.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    Section {
                        Toggle("Show Percentage", isOn: $circularHUDShowValue)
                        Toggle("Use Accent Color", isOn: $circularHUDUseAccentColor)
                        Defaults.Toggle(key: .useColorCodedVolumeDisplay) {
                            Text("Color-coded Volume")
                        }
                        if Defaults[.useColorCodedVolumeDisplay] {
                            Defaults.Toggle(key: .useSmoothColorGradient) {
                                Text("Smooth color transitions")
                            }
                        }
                    } header: {
                        Text("Style")
                    }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Size: \(Int(circularHUDSize))px")
                            Slider(value: $circularHUDSize, in: 40...200, step: 5)
                        }
                        VStack(alignment: .leading) {
                            Text("Line Width: \(Int(circularHUDStrokeWidth))px")
                            Slider(value: $circularHUDStrokeWidth, in: 2...16, step: 1)
                        }
                        Button("Reset to Default") {
                            circularHUDSize = 65
                            circularHUDStrokeWidth = 4
                        }
                    } header: {
                        Text("Dimensions")
                    }
                }
            }

            // Third-party display integrations (shared across all HUD variants)
            ExternalDisplayIntegrationsSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(paneBackgroundColor)
        .navigationTitle("Controls")
        .onAppear {
            if #unavailable(macOS 26.0), verticalHUDMaterial == .liquid {
                verticalHUDMaterial = .frosted
                verticalHUDLiquidGlassCustomizationMode = .standard
            }
        }
    }
}

// MARK: - External Display Integrations Settings Section

private struct ExternalDisplayIntegrationsSection: View {
    @Default(.enableThirdPartyDDCIntegration) var enableThirdPartyDDCIntegration
    @Default(.thirdPartyDDCProvider) var thirdPartyDDCProvider
    @Default(.enableExternalVolumeControlListener) var enableExternalVolumeControlListener
    @Default(.volumeStepPercent) var volumeStepPercent
    @Default(.volumeFineStepPercent) var volumeFineStepPercent
    @Default(.brightnessStepPercent) var brightnessStepPercent
    @Default(.brightnessFineStepPercent) var brightnessFineStepPercent
    @ObservedObject private var betterDisplayManager = BetterDisplayManager.shared
    @ObservedObject private var lunarManager = LunarManager.shared

    private func highlightID(_ title: String) -> String {
        SettingsTab.hudAndOSD.highlightID(for: title)
    }

    private var providerStatusText: String {
        switch thirdPartyDDCProvider {
        case .betterDisplay:
            if betterDisplayManager.isRunning { return "Running" }
            if betterDisplayManager.isDetected { return "Not running" }
            return "Not detected"
        case .lunar:
            if lunarManager.isConnected { return "Connected" }
            if lunarManager.isRunning { return "Running" }
            if lunarManager.isDetected { return "Not running" }
            return "Not detected"
        }
    }

    private var providerStatusColor: Color {
        switch thirdPartyDDCProvider {
        case .betterDisplay:
            if betterDisplayManager.isRunning { return .green }
            if betterDisplayManager.isDetected { return .orange }
            return .secondary
        case .lunar:
            if lunarManager.isConnected { return .green }
            if lunarManager.isRunning { return .orange }
            if lunarManager.isDetected { return .orange }
            return .secondary
        }
    }

    private var providerStatusDescription: String {
        switch thirdPartyDDCProvider {
        case .betterDisplay:
            if !betterDisplayManager.isDetected {
                return "Install [BetterDisplay](https://betterdisplay.pro) to control external display brightness (and optional volume) through Atoll's HUD."
            }
            if !betterDisplayManager.isRunning {
                return "BetterDisplay is installed but not currently running. Launch BetterDisplay to enable integration."
            }
            return "BetterDisplay OSD events will be routed through Atoll's active HUD style. Brightness is always routed; volume is routed when external volume control listener is enabled below. Make sure BetterDisplay's OSD integration is enabled in Settings › Application › Integration."
        case .lunar:
            if !lunarManager.isDetected {
                return "Install [Lunar](https://lunar.fyi) to control external display brightness, contrast, and optional volume through Atoll's HUD via DDC."
            }
            if !lunarManager.isRunning {
                return "Lunar is installed but not currently running. Launch Lunar to enable integration."
            }
            if lunarManager.isConnected {
                return "Connected to Lunar's DDC socket. Brightness and contrast adjustments are shown through Atoll's HUD; volume follows when external volume control listener is enabled below."
            }
            return "Lunar is running but the socket connection is not yet established. It will connect automatically."
        }
    }

    private func refreshDetectionStatus() {
        switch thirdPartyDDCProvider {
        case .betterDisplay:
            betterDisplayManager.refreshDetectionStatus()
        case .lunar:
            lunarManager.refreshDetectionStatus()
        }
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $volumeStepPercent, in: 1...25) {
                    HStack {
                        Text("Volume step")
                        Spacer()
                        Text("\(volumeStepPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .settingsHighlight(id: highlightID("Volume step"))
                .disabled(enableExternalVolumeControlListener)

                Stepper(value: $volumeFineStepPercent, in: 1...25) {
                    HStack {
                        Text("Volume fine step")
                        Spacer()
                        Text("\(volumeFineStepPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .settingsHighlight(id: highlightID("Volume fine step"))
                .disabled(enableExternalVolumeControlListener)

                if enableExternalVolumeControlListener {
                    Text("Disabled while external display volume integration is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: $brightnessStepPercent, in: 1...25) {
                    HStack {
                        Text("Brightness step")
                        Spacer()
                        Text("\(brightnessStepPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .settingsHighlight(id: highlightID("Brightness step"))
                .disabled(enableThirdPartyDDCIntegration)

                Stepper(value: $brightnessFineStepPercent, in: 1...25) {
                    HStack {
                        Text("Brightness fine step")
                        Spacer()
                        Text("\(brightnessFineStepPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .settingsHighlight(id: highlightID("Brightness fine step"))
                .disabled(enableThirdPartyDDCIntegration)

                if enableThirdPartyDDCIntegration {
                    Text("Disabled while external display brightness integration is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Step size")
            } footer: {
                Text("Percent change per key press. Fine step applies when holding Shift+Option.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Toggle("Enable third-party DDC app integration", isOn: $enableThirdPartyDDCIntegration)
                    .settingsHighlight(id: highlightID("Third-party DDC app integration"))

                if enableThirdPartyDDCIntegration {
                    Picker("Provider", selection: $thirdPartyDDCProvider) {
                        ForEach(ThirdPartyDDCProvider.allCases) { provider in
                            HStack {
                                AppIconImage(
                                    bundleIdentifiers: provider.bundleIdentifiers,
                                    symbolFallback: "display",
                                    symbolColor: .secondary
                                )
                                Text(provider.displayName)
                            }
                            .tag(provider)
                        }
                    }
                    .settingsHighlight(id: highlightID("Third-party DDC provider"))

                    Toggle("Enable external volume control listener", isOn: $enableExternalVolumeControlListener)
                        .settingsHighlight(id: highlightID("Enable external volume control listener"))

                    Text(
                        enableExternalVolumeControlListener
                        ? "Atoll's built-in volume key interception is disabled while external volume listening is on. Volume HUD/OSD will follow \(thirdPartyDDCProvider.displayName) payloads."
                        : "Atoll keeps native volume key interception. External provider volume payloads are ignored while this is off."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Text("Status")
                        Spacer()
                        Text(providerStatusText)
                            .font(.caption)
                            .foregroundStyle(providerStatusColor)
                    }

                    Text(providerStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        refreshDetectionStatus()
                    } label: {
                        Label("Refresh detection", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                } else {
                    Text("Enable to route BetterDisplay or Lunar display adjustments through Atoll's active HUD style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if enableThirdPartyDDCIntegration {
                    Text("Atoll always listens to selected-provider brightness events, and listens to provider volume events only when external volume listener is enabled.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }
}

private struct HUDSelectionCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.clear,
                                    lineWidth: 2.5
                                )
                        )
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

                    preview
                }
                .frame(width: 110, height: 80)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

private struct DevicesSettingsView: View {
    @Default(.progressBarStyle) var progressBarStyle
    @Default(.useBluetoothHUD3DIcon) private var useBluetoothHUD3DIcon

    private func highlightID(_ title: String) -> String {
        SettingsTab.devices.highlightID(for: title)
    }

    private var colorCodingDisabled: Bool {
        progressBarStyle == .segmented
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBluetoothDeviceConnections) {
                    Text("Show Bluetooth device connections")
                }
                .settingsHighlight(id: highlightID("Show Bluetooth device connections"))
                Defaults.Toggle(key: .useCircularBluetoothBatteryIndicator) {
                    Text("Use circular battery indicator")
                }
                .settingsHighlight(id: highlightID("Use circular battery indicator"))
                Defaults.Toggle(key: .showBluetoothBatteryPercentageText) {
                    Text("Show battery percentage text in HUD")
                }
                .settingsHighlight(id: highlightID("Show battery percentage text in HUD"))
                Defaults.Toggle(key: .showBluetoothDeviceNameMarquee) {
                    Text("Scroll device name in HUD")
                }
                .settingsHighlight(id: highlightID("Scroll device name in HUD"))
                Defaults.Toggle(key: .showAirPodsListeningModeChanges) {
                    Text("Show AirPods listening mode changes")
                }
                .settingsHighlight(id: highlightID("Show AirPods listening mode changes"))
                VStack(alignment: .leading, spacing: 12) {
                    Text("HUD icon style")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 16) {
                        Spacer(minLength: 0)
                        BluetoothHUDIconStyleCard(
                            style: .symbol,
                            isSelected: !useBluetoothHUD3DIcon
                        ) {
                            useBluetoothHUD3DIcon = false
                        }
                        BluetoothHUDIconStyleCard(
                            style: .threeD,
                            isSelected: useBluetoothHUD3DIcon
                        ) {
                            useBluetoothHUD3DIcon = true
                        }
                        Spacer(minLength: 0)
                    }
                }
                .settingsHighlight(id: highlightID("Use 3D Bluetooth HUD icon"))
            } header: {
                Text("Bluetooth Audio Devices")
            } footer: {
                Text("Displays a HUD notification when Bluetooth audio devices (headphones, AirPods, speakers) connect, showing device name and battery level.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .useColorCodedBatteryDisplay) {
                    Text("Color-coded battery display")
                }
                .disabled(colorCodingDisabled)
                .settingsHighlight(id: highlightID("Color-coded battery display"))
            } header: {
                Text("Battery Indicator Styling")
            } footer: {
                if progressBarStyle == .segmented {
                    Text("Color-coded fills are unavailable in Segmented mode. Switch to Hierarchical or Gradient inside Controls › Dynamic Island to adjust advanced options.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else if Defaults[.useSmoothColorGradient] {
                    Text("Smooth transitions blend Green (0–60%), Yellow (60–85%), and Red (85–100%) through the entire fill. Adjust gradient behavior from Controls › Dynamic Island.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Text("Discrete transitions snap between Green (0–60%), Yellow (60–85%), and Red (85–100%).")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Devices")
    }
}

struct HUD: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @Default(.inlineHUD) var inlineHUD
    @Default(.progressBarStyle) var progressBarStyle
    @Default(.enableSystemHUD) var enableSystemHUD
    @Default(.enableVolumeHUD) var enableVolumeHUD
    @Default(.enableBrightnessHUD) var enableBrightnessHUD
    @Default(.enableKeyboardBacklightHUD) var enableKeyboardBacklightHUD
    @Default(.enableThirdPartyDDCIntegration) var enableThirdPartyDDCIntegration
    @Default(.systemHUDSensitivity) var systemHUDSensitivity
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var accessibilityPermission = AccessibilityPermissionStore.shared

    private func highlightID(_ title: String) -> String {
        SettingsTab.hudAndOSD.highlightID(for: title)
    }

    private var hasAccessibilityPermission: Bool {
        accessibilityPermission.isAuthorized
    }

    private var colorCodingDisabled: Bool {
        progressBarStyle == .segmented
    }

    var body: some View {
        Form {
            if !hasAccessibilityPermission && !enableThirdPartyDDCIntegration {
                Section {
                    SettingsPermissionCallout(
                        message: "Accessibility permission lets Dynamic Island replace the native volume, brightness, and keyboard HUDs.",
                        requestAction: { accessibilityPermission.requestAuthorizationPrompt() },
                        openSettingsAction: { accessibilityPermission.openSystemSettings() }
                    )
                } header: {
                    Text("Accessibility")
                }
            }



            if enableSystemHUD && !Defaults[.enableCustomOSD] && (hasAccessibilityPermission || enableThirdPartyDDCIntegration) {
                Section {
                    Toggle("Volume HUD", isOn: $enableVolumeHUD)
                    Toggle("Brightness HUD", isOn: $enableBrightnessHUD)
                    Toggle("Keyboard Backlight HUD", isOn: $enableKeyboardBacklightHUD)
                        .disabled(enableThirdPartyDDCIntegration)
                        .help(enableThirdPartyDDCIntegration ? "Disabled while external display integration is active \u{2014} brightness keys are handled by the external app." : "")
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Choose which system controls should display HUD notifications.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                Defaults.Toggle(key: .playVolumeChangeFeedback) {
                    Text("Play feedback when volume is changed")
                }
                .settingsHighlight(id: highlightID("Play feedback when volume is changed"))
                .help("Plays the supplied feedback clip whenever you press the hardware volume keys.")
            } header: {
                Text("Audio feedback")
            } footer: {
                Text("Requires Accessibility permission so Dynamic Island can intercept the hardware volume keys.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .useColorCodedVolumeDisplay) {
                    Text("Color-coded volume display")
                }
                .disabled(colorCodingDisabled)
                .settingsHighlight(id: highlightID("Color-coded volume display"))

                if !colorCodingDisabled && (Defaults[.useColorCodedBatteryDisplay] || Defaults[.useColorCodedVolumeDisplay]) {
                    Defaults.Toggle(key: .useSmoothColorGradient) {
                        Text("Smooth color transitions")
                    }
                    .settingsHighlight(id: highlightID("Smooth color transitions"))
                }

                Defaults.Toggle(key: .showProgressPercentages) {
                    Text("Show percentages beside progress bars")
                }
                .settingsHighlight(id: highlightID("Show percentages beside progress bars"))
            } header: {
                Text("Dynamic Island Progress Bars")
            } footer: {
                if colorCodingDisabled {
                    Text("Color-coded fills and smooth gradients are unavailable in Segmented mode. Switch to Hierarchical or Gradient to adjust these options.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else if Defaults[.useSmoothColorGradient] {
                    Text("Smooth transitions blend Green (0–60%), Yellow (60–85%), and Red (85–100%) through the entire fill.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Text("Discrete transitions snap between Green (0–60%), Yellow (60–85%), and Red (85–100%).")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                Picker("HUD style", selection: $inlineHUD) {
                    Text("Default")
                        .tag(false)
                    Text("Inline")
                        .tag(true)
                }
                .settingsHighlight(id: highlightID("HUD style"))
                .onChange(of: Defaults[.inlineHUD]) {
                    if Defaults[.inlineHUD] {
                        withAnimation {
                            Defaults[.systemEventIndicatorShadow] = false
                            Defaults[.progressBarStyle] = .hierarchical
                        }
                    }
                }
                Picker("Progressbar style", selection: $progressBarStyle) {
                    Text("Hierarchical")
                        .tag(ProgressBarStyle.hierarchical)
                    Text("Gradient")
                        .tag(ProgressBarStyle.gradient)
                    Text("Segmented")
                        .tag(ProgressBarStyle.segmented)
                }
                .settingsHighlight(id: highlightID("Progressbar style"))
                Defaults.Toggle(key: .systemEventIndicatorShadow) {
                    Text("Enable glowing effect")
                }
                .settingsHighlight(id: highlightID("Enable glowing effect"))
                Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                    Text("Use accent color")
                }
                .settingsHighlight(id: highlightID("Use accent color"))
            } header: {
                HStack {
                    Text("Appearance")
                }
            }
        }
        .navigationTitle("Controls")
        .onAppear {
            accessibilityPermission.refreshStatus()
        }
        .onChange(of: accessibilityPermission.isAuthorized) { _, granted in
            if !granted {
                enableSystemHUD = false
            }
        }
    }
}

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.showShuffleAndRepeat) private var showShuffleAndRepeat
    @Default(.musicSkipBehavior) private var musicSkipBehavior
    @Default(.musicControlWindowEnabled) private var musicControlWindowEnabled
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.showSneakPeekOnTrackChange) private var showSneakPeekOnTrackChange
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenMusicAlbumParallaxEnabled) private var lockScreenMusicAlbumParallaxEnabled
    @Default(.lockScreenMusicFullscreenArtworkEnabled) private var lockScreenMusicFullscreenArtworkEnabled
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.autoHideInactiveNotchMediaPlayer) private var autoHideInactiveNotchMediaPlayer
    @Default(.visualizerBarCount) private var visualizerBarCount
    @Default(.enableWaveformScrubber) private var enableWaveformScrubber
    @Default(.colorExtractionMode) private var colorExtractionMode
    @Default(.parallaxEffectIntensity) private var parallaxEffectIntensity

    
    @ObservedObject private var musicManager = MusicManager.shared

    private var isAppleMusicActive: Bool {
        musicManager.bundleIdentifier == "com.apple.Music"
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.media.highlightID(for: title)
    }

    private var standardControlsSuppressed: Bool {
        !showStandardMediaControls && !enableMinimalisticUI
    }

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: $mediaController) {
                    ForEach(availableMediaControllers) { controller in
                        Text(controller.localizedName).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }
                .settingsHighlight(id: highlightID("Music Source"))
            } header: {
                Text("Media Source")
            } footer: {
                if MusicManager.shared.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link("https://github.com/th-ch/youtube-music", destination: URL(string: "https://github.com/th-ch/youtube-music")!)
                            .font(.caption)
                            .foregroundColor(.blue) // Ensures it's visibly a link
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "'Now Playing' was the only option on previous versions and works with all media apps."))
                        Text(String(localized: "Uses macOS Now Playing when the Amazon Music app is the active media source. Playback controls follow the system Now Playing target. Scrubbing the timeline may not work if the Amazon Music app does not support remote seek."))
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }

            if mediaController == .spotify {
                SpotifyAuthSettingsSection()
            }

            Section {
                Defaults.Toggle(key: .showStandardMediaControls) {
                    Text("Show media controls in Dynamic Island")
                }
                .disabled(enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Show media controls in Dynamic Island"))

                Defaults.Toggle(key: .autoHideInactiveNotchMediaPlayer) {
                    Text("Auto-hide inactive notch media player")
                }
                .disabled(enableMinimalisticUI || !showStandardMediaControls)
                .settingsHighlight(id: highlightID("Auto-hide inactive notch media player"))

                if enableMinimalisticUI {
                    Text("Disable Minimalistic UI to configure the standard notch media controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if standardControlsSuppressed {
                    Text("Standard notch media controls are hidden. Re-enable the toggle above to restore them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !autoHideInactiveNotchMediaPlayer {
                    Text("When disabled, the notch music player stays visible with placeholder metadata even when playback is inactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Dynamic Island Visibility")
            }
            Section {
                Defaults.Toggle(key: .showShuffleAndRepeat) {
                    HStack {
                        Text("Enable customizable controls")
                        customBadge(text: "Beta")
                    }
                }
                if showShuffleAndRepeat {
                    Defaults.Toggle(key: .showMediaOutputControl) {
                        Text("Show \"Change Media Output\" control")
                    }
                    .settingsHighlight(id: highlightID("Show Change Media Output control"))
                    .help("Adds the AirPlay/route picker button back to the customizable controls palette.")
                    MusicSlotConfigurationView()
                } else {
                    Text("Turn on customizable controls to rearrange media buttons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Media controls")
            }

            Section(header: Text("Lock Screen Media")) {
                Defaults.Toggle(key: .lockScreenMusicAlbumParallaxEnabled) {
                    Text("Enable album art parallax")
                }
                .settingsHighlight(id: highlightID("Enable album art parallax"))
                Text("Applies the notch-style parallax effect to the lock screen media widget album art.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if musicControlWindowEnabled {
                Section {
                    Picker("Skip buttons", selection: $musicSkipBehavior) {
                        ForEach(MusicSkipBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Skip buttons"))

                    Text(musicSkipBehavior.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Floating window panel skip behaviour")
                }
            }
            Section {
                Toggle(
                    "Enable music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                .disabled(standardControlsSuppressed)
                .help(standardControlsSuppressed ? "Standard notch media controls are hidden while this toggle is off." : "")
                Defaults.Toggle(key: .musicControlWindowEnabled) {
                    Text("Show floating media controls")
                }
                .disabled(!coordinator.musicLiveActivityEnabled || standardControlsSuppressed)
                .help("Displays play/pause and skip buttons beside the notch while music is active. Disabled by default.")
                Toggle("Enable sneak peek", isOn: $enableSneakPeek)
                Toggle("Show sneak peek on playback changes", isOn: $showSneakPeekOnTrackChange)
                    .disabled(!enableSneakPeek)
                Defaults.Toggle(key: .enableLyrics) {
                    Text("Enable lyrics")
                }
                .settingsHighlight(id: highlightID("Enable lyrics"))
                Defaults.Toggle(key: .showLiveCanvasInDynamicIsland) {
                    Text("Show live canvas in Dynamic Island")
                }
                .settingsHighlight(id: highlightID("Show live canvas in Dynamic Island"))
                .help("Replaces the artwork tile with the live canvas when the current app provides one, and reuses that moving canvas for the surrounding lighting effect.")
                
                //Parallax Effect Intensity to control how much parallax is wanted
                Slider(value: $parallaxEffectIntensity, in: 0...12, step: 1.0) {
                    HStack {
                        Text("Parallax Effect Intensity")
                        Spacer()
                        Text("\(parallaxEffectIntensity, specifier: "%0.1f")")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("Enable album art parallax effect"))
                
                Picker("Sneak Peek Style", selection: $sneakPeekStyles){
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .disabled(!enableSneakPeek)
                .settingsHighlight(id: highlightID("Sneak Peek Style"))

                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Defaults.Toggle(key: .showSongMetadataInClosedNotch) {
                    Text("Show song title and artist on non-notch displays")
                }
                .settingsHighlight(id: highlightID("Show song title and artist in closed notch"))
            } header: {
                Text("Media playback live activity")
            }

            Section {
                Defaults.Toggle(key: .enableRealTimeWaveform) {
                    HStack {
                        Text("Enable real-time waveform")
                        customBadge(text: "Beta")
                    }
                }
                .settingsHighlight(id: highlightID("Enable real-time waveform"))
                
                Picker("Visualizer candles", selection: $visualizerBarCount) {
                    Text("4").tag(4)
                    Text("5").tag(5)
                    Text("6").tag(6)
                }
                
                Picker("Color extraction", selection: $colorExtractionMode) {
                    Text("Legacy").tag(ColorExtractionMode.legacy)
                    Text("Vibrant").tag(ColorExtractionMode.vibrant)
                }
                
                Toggle("Scrubbable real-time waveform", isOn: $enableWaveformScrubber)
            } header: {
                Text("Music Visualizer")
            } footer: {
                Text("When enabled, the music visualizer displays real-time audio spectrum data synced to your music. Requires macOS 14.2+ and uses minimal CPU/GPU resources via the Accelerate framework.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenMediaWidget) {
                    Text("Show lock screen media panel")
                }
                Defaults.Toggle(key: .lockScreenShowAppIcon) {
                    Text("Show media app icon")
                }
                .disabled(!enableLockScreenMediaWidget)
                if isAppleMusicActive {
                    Defaults.Toggle(key: .lockScreenMusicMergedAirPlayOutput) {
                        Text("Show merged AirPlay and output devices")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Show merged AirPlay and output devices"))
                }
                Defaults.Toggle(key: .lockScreenPanelShowsBorder) {
                    Text("Show panel border")
                }
                .disabled(!enableLockScreenMediaWidget)
                if lockScreenGlassCustomizationMode == .customLiquid {
                    Defaults.Toggle(key: .lockScreenMusicUsesEnhancedLiquidBorder) {
                        Text("Use enhanced liquid border")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                }
                if lockScreenGlassCustomizationMode == .customLiquid {
                    customLiquidBlurRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else if lockScreenGlassStyle == .frosted {
                    Defaults.Toggle(key: .lockScreenPanelUsesBlur) {
                        Text("Enable media panel blur")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else {
                    unavailableBlurRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Defaults.Toggle(key: .lockScreenMusicFullscreenArtworkEnabled) {
                        Text("Fullscreen artwork on right-click")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Fullscreen artwork on right-click"))
                    Defaults.Toggle(key: .lockScreenUseArtworkLayoutOverFullscreenCanvas) {
                        Text("Use album art layout over fullscreen canvas")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Use album art layout over fullscreen canvas"))
                    Defaults.Toggle(key: .lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork) {
                        Text("Keep album art visible during fullscreen artwork")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Keep album art visible during fullscreen artwork"))
                    Text("Right-click the album art on the lock screen to set it as the wallpaper. Right-click again or click the background to restore the original wallpaper. If a canvas is available, Atoll can also keep the same album art + player layout on top of the live canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Lock Screen Integration")
            } footer: {
                Text("These controls mirror the Lock Screen tab so you can tune the media overlay while focusing on playback settings.")
            }
            .disabled(!showStandardMediaControls)
            .opacity(showStandardMediaControls ? 1 : 0.5)

            Picker(selection: $hideNotchOption, label:
                    HStack {
                Text("Hide DynamicIsland Options")
                customBadge(text: "Beta")
            }) {
                Text("Always hide in fullscreen").tag(HideNotchOption.always)
                Text("Hide only when NowPlaying app is in fullscreen").tag(HideNotchOption.nowPlayingOnly)
                Text("Never hide").tag(HideNotchOption.never)
            }
            .onChange(of: hideNotchOption) {
                Defaults[.enableFullscreenMediaDetection] = hideNotchOption != .never
            }
        }
        .navigationTitle("Media")
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }

    private var unavailableBlurRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Only applies when Material is set to Frosted Glass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var customLiquidBlurRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Custom liquid glass already renders with Apple's liquid material, so this option is managed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct About: View {
    @State private var showBuildNumber: Bool = false
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName])
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()

                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unkown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(sponsorPage)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            Text("Donate")
                                .foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(productPage)
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            Text("GitHub")
                                .foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
                
                Text("Your support funds software development learning for students in 9th–12th grade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 5)

                VStack(spacing: 0) {
                    Divider()
                        .padding(.bottom, 5)
                    Text("Made with ❤️ by Ebullioscopic")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 7)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("About")
    }
}

private extension DevicesSettingsView {
    enum BluetoothHUDIconStyle: String {
        case symbol
        case threeD

        var title: String {
            switch self {
            case .symbol:
                return "Symbol"
            case .threeD:
                return "3D"
            }
        }
    }

    struct BluetoothHUDIconStyleCard: View {
        let style: BluetoothHUDIconStyle
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                        )

                    preview
                }
                .frame(width: 90, height: 64)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovering = hovering
                    }
                }

                Text(style.title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .contentShape(Rectangle())
            .onTapGesture { action() }
        }

        private var preview: some View {
            Group {
                switch style {
                case .symbol:
                    Image(systemName: BluetoothAudioDeviceType.airpods.sfSymbol)
                        .font(.system(size: 24, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                case .threeD:
                    if let url = Bundle.main.url(
                        forResource: BluetoothAudioDeviceType.airpods.inlineHUDAnimationBaseName,
                        withExtension: "mov",
                        subdirectory: "BluetoothHUDAnimations"
                    ) ?? Bundle.main.url(
                        forResource: BluetoothAudioDeviceType.airpods.inlineHUDAnimationBaseName,
                        withExtension: "mov"
                    ) {
                        SettingsLoopingVideoIcon(url: url, size: CGSize(width: 28, height: 28))
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: BluetoothAudioDeviceType.airpods.sfSymbol)
                            .font(.system(size: 24, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }

        private var backgroundColor: Color {
            if isSelected { return Color.accentColor.opacity(0.12) }
            if isHovering { return Color.primary.opacity(0.05) }
            return Color(nsColor: .controlBackgroundColor)
        }

        private var borderColor: Color {
            if isSelected { return Color.accentColor }
            if isHovering { return Color.primary.opacity(0.1) }
            return Color.clear
        }
    }
}

private struct SettingsLoopingVideoIcon: NSViewRepresentable {
    let url: URL
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true

        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        context.coordinator.attach(layer: layer, url: url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var controller: SettingsLoopingPlayerController?

        func attach(layer: AVPlayerLayer, url: URL) {
            controller = SettingsLoopingPlayerController(url: url, autoPlay: true)
            layer.player = controller?.player
        }
    }
}

private final class SettingsLoopingPlayerController {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL, autoPlay: Bool = true) {
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: item)
        if autoPlay {
            player.play()
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    deinit {
        player.pause()
        looper = nil
    }
}

struct Shelf: View {
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection
    @Default(.copyOnDrag) var copyOnDrag
    @Default(.autoRemoveShelfItems) var autoRemoveShelfItems
    @StateObject private var quickShareService = QuickShareService.shared
    @ObservedObject private var fullDiskAccessPermission = FullDiskAccessPermissionStore.shared
    @ObservedObject private var shelfFolderAccessPermission = ShelfFolderAccessPermissionStore.shared

    private var hasDocumentsAndDownloadsAccess: Bool {
        shelfFolderAccessPermission.hasDocumentsAndDownloadsAccess
    }

    private var canEnableShelf: Bool {
        fullDiskAccessPermission.isAuthorized || hasDocumentsAndDownloadsAccess
    }

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    init() {
        QuickShareService.shared.ensureDiscovered()
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.shelf.highlightID(for: title)
    }

    var body: some View {
        Form {
            if !canEnableShelf || !fullDiskAccessPermission.isAuthorized {
                Section {
                    if !canEnableShelf {
                        SettingsPermissionCallout(
                            title: "Additional folder access required",
                            message: "Enable Full Disk Access, or grant access to both Documents and Downloads folders to use Shelf.",
                            icon: "folder.badge.questionmark",
                            iconColor: .orange,
                            requestButtonTitle: "Request Folder Access",
                            openSettingsButtonTitle: "Open Privacy & Security",
                            requestAction: { shelfFolderAccessPermission.requestAccessPrompt() },
                            openSettingsAction: { shelfFolderAccessPermission.openSystemSettings() }
                        )
                    }

                    if !fullDiskAccessPermission.isAuthorized {
                        SettingsPermissionCallout(
                            title: "Full Disk Access for global mode",
                            message: "Without Full Disk Access, Shelf can only read files from Documents and Downloads. Grant Full Disk Access to make Shelf work globally.",
                            icon: "externaldrive.fill",
                            iconColor: .purple,
                            requestButtonTitle: "Request Full Disk Access",
                            openSettingsButtonTitle: "Open Privacy & Security",
                            requestAction: { fullDiskAccessPermission.requestAccessPrompt() },
                            openSettingsAction: { fullDiskAccessPermission.openSystemSettings() }
                        )
                    }
                } header: {
                    Text("Permissions")
                }
            }

            Section {
                Defaults.Toggle(key: .dynamicShelf) {
                    Text("Enable shelf")
                }
                .disabled(!canEnableShelf)
                .settingsHighlight(id: highlightID("Enable shelf"))

                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf tab by default if items added")
                }
                .settingsHighlight(id: highlightID("Open shelf tab by default if items added"))

                Defaults.Toggle(key: .expandedDragDetection) {
                    Text("Expanded drag detection area")
                }
                .settingsHighlight(id: highlightID("Expanded drag detection area"))

                Defaults.Toggle(key: .copyOnDrag) {
                    Text("Copy items on drag")
                }
                .settingsHighlight(id: highlightID("Copy items on drag"))

                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                .settingsHighlight(id: highlightID("Remove from shelf after dragging"))
            } header: {
                HStack {
                    Text("General")
                }
            }

            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            QuickShareProviderIconImage(provider: provider, size: 16)
                            Text(provider.id)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .settingsHighlight(id: highlightID("Quick Share Service"))

                if let selectedProvider {
                    HStack {
                        QuickShareProviderIconImage(provider: selectedProvider, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Files dropped on the shelf will be shared via this service")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Quick Share")
                }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Drag files onto the shelf or click the shelf button to pick files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if quickShareProvider == "LocalSend" {
                LocalSendSettingsSection(highlightID: highlightID)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shelf")
        .onAppear {
            fullDiskAccessPermission.refreshStatus()
            shelfFolderAccessPermission.refreshStatus()
        }
    }
}

// MARK: - LocalSend Settings Section

private struct LocalSendSettingsSection: View {
    let highlightID: (String) -> String
    
    @Default(.localSendDevicePickerGlassMode) private var glassMode
    @Default(.localSendDevicePickerLiquidGlassVariant) private var liquidGlassVariant
    
    var body: some View {
        Section {
            Picker("Device Picker Style", selection: $glassMode) {
                ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            
            if glassMode == .customLiquid {
                Picker("Liquid Glass Variant", selection: $liquidGlassVariant) {
                    ForEach(LiquidGlassVariant.allCases) { variant in
                        Text("Variant \(variant.rawValue)").tag(variant)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("LocalSend Device Picker")
        } footer: {
            Text("Customize the appearance of the LocalSend device selection popup that appears when you drop files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LiveActivitiesSettings: View {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    @ObservedObject var privacyManager = PrivacyIndicatorManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject private var fullDiskAccessPermission = FullDiskAccessPermissionStore.shared

    @Default(.enableScreenRecordingDetection) var enableScreenRecordingDetection
    @Default(.enableDoNotDisturbDetection) var enableDoNotDisturbDetection
    @Default(.focusIndicatorNonPersistent) var focusIndicatorNonPersistent
    @Default(.capsLockIndicatorTintMode) var capsLockTintMode

    private func highlightID(_ title: String) -> String {
        SettingsTab.liveActivities.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableScreenRecordingDetection) {
                    Text("Enable Screen Recording Detection")
                }
                .settingsHighlight(id: highlightID("Enable Screen Recording Detection"))

                Defaults.Toggle(key: .showRecordingIndicator) {
                    Text("Show Recording Indicator")
                }
                .disabled(!enableScreenRecordingDetection)
                .settingsHighlight(id: highlightID("Show Recording Indicator"))

                if recordingManager.isMonitoring {
                    HStack {
                        Text("Detection Status")
                        Spacer()
                        if recordingManager.isRecording {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text("Recording Detected")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Text("Active - No Recording")
                                .foregroundColor(.green)
                        }
                    }
                }
            } header: {
                Text("Screen Recording")
            } footer: {
                Text("Uses event-driven private API for real-time screen recording detection")
            }

            Section {
                if !fullDiskAccessPermission.isAuthorized {
                    SettingsPermissionCallout(
                        title: String(localized: "Custom Focus metadata"),
                        message: String(localized: "Full Disk Access unlocks custom Focus icons, colors, and labels. Standard Focus detection still works without it—grant access only if you need personalized indicators."),
                        icon: "externaldrive.fill",
                        iconColor: .purple,
                        requestButtonTitle: String(localized: "Request Full Disk Access"),
                        openSettingsButtonTitle: String(localized: "Open Privacy & Security"),
                        requestAction: { fullDiskAccessPermission.requestAccessPrompt() },
                        openSettingsAction: { fullDiskAccessPermission.openSystemSettings() }
                    )
                }

                Defaults.Toggle(key: .enableDoNotDisturbDetection) {
                    Text("Enable Focus Detection")
                }
                .settingsHighlight(id: highlightID("Enable Focus Detection"))

                Defaults.Toggle(key: .showDoNotDisturbIndicator) {
                    Text("Show Focus Indicator")
                }
                .disabled(!enableDoNotDisturbDetection)
                .settingsHighlight(id: highlightID("Show Focus Indicator"))

                Defaults.Toggle(key: .showDoNotDisturbLabel) {
                    Text("Show Focus Label")
                }
                .disabled(!enableDoNotDisturbDetection || focusIndicatorNonPersistent)
                .help(focusIndicatorNonPersistent ? "Labels are forced to compact on/off text while brief toast mode is enabled." : "Show the active Focus name inside the indicator.")
                .settingsHighlight(id: highlightID("Show Focus Label"))

                Defaults.Toggle(key: .focusIndicatorNonPersistent) {
                    Text("Show Focus as brief toast")
                }
                .disabled(!enableDoNotDisturbDetection)
                .settingsHighlight(id: highlightID("Show Focus as brief toast"))
                .help("When enabled, Focus appears briefly (on/off) and then collapses instead of staying visible.")

                if doNotDisturbManager.isMonitoring {
                    HStack {
                        Text("Focus Status")
                        Spacer()
                        if doNotDisturbManager.isDoNotDisturbActive {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: 8, height: 8)
                                Text(doNotDisturbManager.currentFocusModeName.isEmpty ? "Focus Enabled" : doNotDisturbManager.currentFocusModeName)
                                    .foregroundColor(.purple)
                            }
                        } else {
                            Text("Active - No Focus")
                                .foregroundColor(.green)
                        }
                    }
                } else {
                    HStack {
                        Text("Focus Status")
                        Spacer()
                        Text("Disabled")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Do Not Disturb")
            } footer: {
                Text("Listens for Focus session changes via distributed notifications")
            }

            Section {
                Defaults.Toggle(key: .enableCapsLockIndicator) {
                    Text("Show Caps Lock Indicator")
                }
                .settingsHighlight(id: highlightID("Show Caps Lock Indicator"))

                Defaults.Toggle(key: .showCapsLockLabel) {
                    Text("Show Caps Lock label")
                }
                .disabled(!Defaults[.enableCapsLockIndicator])
                .settingsHighlight(id: highlightID("Show Caps Lock label"))

                Picker("Caps Lock color", selection: $capsLockTintMode) {
                    ForEach(CapsLockIndicatorTintMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!Defaults[.enableCapsLockIndicator])
                .settingsHighlight(id: highlightID("Caps Lock color"))
            } header: {
                Text("Caps Lock Indicator")
            } footer: {
                Text("Adds a notch HUD when Caps Lock is enabled, with optional label and tint controls.")
            }

            Section {
                Defaults.Toggle(key: .enableCameraDetection) {
                    Text("Enable Camera Detection")
                }
                .settingsHighlight(id: highlightID("Enable Camera Detection"))
                Defaults.Toggle(key: .enableMicrophoneDetection) {
                    Text("Enable Microphone Detection")
                }
                .settingsHighlight(id: highlightID("Enable Microphone Detection"))

                if privacyManager.isMonitoring {
                    HStack {
                        Text("Camera Status")
                        Spacer()
                        if privacyManager.cameraActive {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Camera Active")
                                    .foregroundColor(.green)
                            }
                        } else {
                            Text("Inactive")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Microphone Status")
                        Spacer()
                        if privacyManager.microphoneActive {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.yellow)
                                    .frame(width: 8, height: 8)
                                Text("Microphone Active")
                                    .foregroundColor(.yellow)
                            }
                        } else {
                            Text("Inactive")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Privacy Indicators")
            } footer: {
                Text("Shows green camera icon and yellow microphone icon when in use. Uses event-driven CoreAudio and CoreMediaIO APIs.")
            }

            Section {
                Toggle(
                    "Enable music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                .settingsHighlight(id: highlightID("Enable music live activity"))
            } header: {
                Text("Media Live Activity")
            } footer: {
                Text("Use the Media tab to configure sneak peek, lyrics, and floating media controls.")
            }

        }
        .navigationTitle("Live Activities")
        .onAppear {
            fullDiskAccessPermission.refreshStatus()
        }
    }
}

struct Appearance: View {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var webcamManager = WebcamManager.shared
    @Default(.mirrorShape) var mirrorShape
    @Default(.selectedCameraID) var selectedCameraID
    @Default(.sliderColor) var sliderColor
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.customVisualizers) var customVisualizers
    @Default(.selectedVisualizer) var selectedVisualizer
    @Default(.customAppIcons) private var customAppIcons
    @Default(.selectedAppIconID) private var selectedAppIconID
    @Default(.openNotchWidth) var openNotchWidth
    @Default(.closedNotchWidth) var closedNotchWidth
    @Default(.customizePhysicalNotchWidth) var customizePhysicalNotchWidth
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenMusicLiquidGlassVariant) private var lockScreenMusicLiquidGlassVariant
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.externalDisplayStyle) private var externalDisplayStyle
    @State private var selectedListVisualizer: CustomVisualizer? = nil

    @State private var isIconImporterPresented = false
    @State private var isIconDropTarget = false
    @State private var iconImportError: String?

    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0

    /// Whether the main screen has a physical notch.
    private var mainScreenHasPhysicalNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidthRange: ClosedRange<Double> {
        let minW = Double(currentRecommendedMinimumNotchWidth())
        let maxW = min(900, Double(maxAllowedNotchWidth()))
        return minW...max(minW, maxW)
    }
    private var defaultOpenNotchWidth: CGFloat {
        currentRecommendedMinimumNotchWidth()
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.appearance.highlightID(for: title)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var appearanceMusicVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenMusicLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenMusicLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Settings icon in notch")
                }
                .settingsHighlight(id: highlightID("Settings icon in notch"))
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                .settingsHighlight(id: highlightID("Enable window shadow"))
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Corner radius scaling")
                }
                .settingsHighlight(id: highlightID("Corner radius scaling"))
                Defaults.Toggle(key: .useModernCloseAnimation) {
                    Text("Use simpler close animation")
                }
                .settingsHighlight(id: highlightID("Use simpler close animation"))
            } header: {
                Text("General")
            }

            // Show display style picker only on non-notch Macs (main screen has no physical notch)
            if !mainScreenHasPhysicalNotch {
                Section {
                    Picker("Main screen style", selection: $externalDisplayStyle) {
                        ForEach(ExternalDisplayStyle.allCases) { style in
                            Text(style.localizedName)
                                .tag(style)
                        }
                    }
                    .onChange(of: externalDisplayStyle) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                    .settingsHighlight(id: highlightID("Main screen style"))
                    Text(externalDisplayStyle.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Display Style")
                }
            }

            notchWidthControls()

            Section {
                if #available(macOS 26.0, *) {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .settingsHighlight(id: highlightID("Lock screen material"))
                } else {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(true)
                    .settingsHighlight(id: highlightID("Lock screen material"))
                    Text("Liquid Glass requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if lockScreenGlassStyle == .liquid {
                    Picker("Lock screen glass mode", selection: $lockScreenGlassCustomizationMode) {
                        ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Lock screen glass mode"))

                    if lockScreenGlassCustomizationMode == .customLiquid {
                        Text("Pick per-widget liquid-glass variants below. Changes mirror the Lock Screen tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Music panel variant")
                                Spacer()
                                Text("v\(lockScreenMusicLiquidGlassVariant.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: appearanceMusicVariantBinding, in: liquidVariantRange, step: 1)

                            LockScreenGlassVariantPreviewCell(variant: $lockScreenMusicLiquidGlassVariant)
                                .padding(.top, 6)
                        }
                        .settingsHighlight(id: highlightID("Music panel variant (appearance)"))
                        .disabled(!enableLockScreenMediaWidget)
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.4)

                    }
                } else {
                    Text("Custom Liquid settings require the Liquid Glass material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lock Screen Glass")
            } footer: {
                Text("Configure lock screen materials from the Appearance tab. Custom Liquid unlocks variant sliders for both widgets whenever Liquid Glass is selected.")
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Enable colored spectrograms")
                }
                .settingsHighlight(id: highlightID("Enable colored spectrograms"))
                Defaults.Toggle(key: .playerColorTinting) {
                    Text("Enable colored spectograms")
                }
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Enable blur effect behind album art")
                }
                .settingsHighlight(id: highlightID("Enable blur effect behind album art"))
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.localizedName)
                    }
                }
                .settingsHighlight(id: highlightID("Slider color"))
            } header: {
                Text("Media")
            }

            Section {
                Toggle(
                    "Use music visualizer spectrogram",
                    isOn: $useMusicVisualizer.animation()
                )
                .disabled(true)
                if !useMusicVisualizer {
                    if customVisualizers.count > 0 {
                        Picker(
                            "Selected animation",
                            selection: $selectedVisualizer
                        ) {
                            ForEach(
                                customVisualizers,
                                id: \.self
                            ) { visualizer in
                                Text(visualizer.name)
                                    .tag(visualizer)
                            }
                        }
                    } else {
                        HStack {
                            Text("Selected animation")
                            Spacer()
                            Text("No custom animation available")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Custom music live activity animation")
                    customBadge(text: "Coming soon")
                }
            }

            Section {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(state: LUStateData(type: .loadedFrom(visualizer.url), speed: visualizer.speed, loopMode: .loop))
                                .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Text("selected")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer != nil ? selectedListVisualizer == visualizer ? Color.accentColor : Color.clear : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedListVisualizer == visualizer {
                                selectedListVisualizer = nil
                                return
                            }
                            selectedListVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(
                    EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
                )
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""
                            url = ""
                            speed = 1.0
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if selectedListVisualizer != nil {
                                let visualizer = selectedListVisualizer!
                                selectedListVisualizer = nil
                                customVisualizers.remove(at: customVisualizers.firstIndex(of: visualizer)!)
                                if visualizer == selectedVisualizer && customVisualizers.count > 0 {
                                    selectedVisualizer = customVisualizers[0]
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("No custom visualizer")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) {
                    VStack(alignment: .leading) {
                        Text("Add new visualizer")
                            .font(.largeTitle.bold())
                            .padding(.vertical)
                        TextField("Name", text: $name)
                        TextField("Lottie JSON URL", text: $url)
                        HStack {
                            Text("Speed")
                            Spacer(minLength: 80)
                            Text("\(speed, specifier: "%.1f")s")
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Slider(value: $speed, in: 0...2, step: 0.1)
                        }
                        .padding(.vertical)
                        HStack {
                            Button {
                                isPresented.toggle()
                            } label: {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }

                            Button {
                                let visualizer: CustomVisualizer = .init(
                                    UUID: UUID(),
                                    name: name,
                                    url: URL(string: url)!,
                                    speed: speed
                                )

                                if !customVisualizers.contains(visualizer) {
                                    customVisualizers.append(visualizer)
                                }

                                isPresented.toggle()
                            } label: {
                                Text("Add")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .controlSize(.extraLarge)
                    .padding()
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Custom vizualizers (Lottie)")
                    if !Defaults[.customVisualizers].isEmpty {
                        Text(" – \(Defaults[.customVisualizers].count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("Enable Dynamic mirror")
                }
                .disabled(!checkVideoInput())
                .settingsHighlight(id: highlightID("Enable Dynamic mirror"))
                Picker("Mirror shape", selection: $mirrorShape) {
                    Text("Circle")
                        .tag(MirrorShapeEnum.circle)
                    Text("Square")
                        .tag(MirrorShapeEnum.rectangle)
                }
                .settingsHighlight(id: highlightID("Mirror shape"))
                
                if webcamManager.cameraAvailable {
                    Picker("Mirror Camera", selection: $selectedCameraID) {
                        ForEach(webcamManager.availableCameras, id: \.uniqueID) { device in
                            Text(device.localizedName)
                                .tag(device.uniqueID)
                        }
                    }
                    .onChange(of: selectedCameraID) { _, _ in
                        if Defaults[.showMirror] {
                            webcamManager.stopSession()
                            webcamManager.startSession()
                        }
                    }
                    .settingsHighlight(id: highlightID("Mirror Camera"))
                }
                Defaults.Toggle(key: .showNotHumanFace) {
                    Text("Idle Animation")
                }
                .settingsHighlight(id: highlightID("Idle Animation"))
            } header: {
                HStack {
                    Text("Additional features")
                }
            }

            // MARK: - Custom Idle Animations Section
            IdleAnimationsSettingsSection()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    let columns = [GridItem(.adaptive(minimum: 90), spacing: 12)]
                    LazyVGrid(columns: columns, spacing: 12) {
                        appIconCard(
                            title: "Default",
                            image: defaultAppIconImage(),
                            isSelected: selectedAppIconID == nil
                        ) {
                            selectedAppIconID = nil
                            applySelectedAppIcon()
                        }

                        ForEach(customAppIcons) { icon in
                            appIconCard(
                                title: icon.name,
                                image: customIconImage(for: icon),
                                isSelected: selectedAppIconID == icon.id.uuidString
                            ) {
                                selectedAppIconID = icon.id.uuidString
                                applySelectedAppIcon()
                            }
                            .contextMenu {
                                Button("Remove") {
                                    removeCustomIcon(icon)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(isIconDropTarget ? 0.18 : 0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isIconDropTarget ? 0.8 : 0), lineWidth: 2)
                    )
                    .onDrop(of: [UTType.fileURL], isTargeted: $isIconDropTarget) { providers in
                        handleIconDrop(providers)
                    }

                    HStack(spacing: 8) {
                        Button("Add icon") {
                            iconImportError = nil
                            isIconImporterPresented = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Remove selected") {
                            if let id = selectedAppIconID,
                               let icon = customAppIcons.first(where: { $0.id.uuidString == id }) {
                                removeCustomIcon(icon)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedAppIconID == nil)
                    }

                    if let iconImportError {
                        Text(iconImportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Drop a PNG, JPEG, TIFF, or ICNS file to add it to your icon library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("App icon"))
            } header: {
                HStack {
                    Text("App icon")
                }
            }
        }
        .onAppear(perform: enforceLockScreenGlassConsistency)
        .onChange(of: lockScreenGlassStyle) { _, _ in enforceLockScreenGlassConsistency() }
        .onChange(of: lockScreenGlassCustomizationMode) { _, _ in enforceLockScreenGlassConsistency() }
        .fileImporter(
            isPresented: $isIconImporterPresented,
            allowedContentTypes: [.png, .jpeg, .tiff, .icns, .image]
        ) { result in
            switch result {
            case .success(let url):
                importCustomIcon(from: url)
            case .failure:
                iconImportError = "Icon import was canceled or failed."
            }
        }
        .navigationTitle("Appearance")
    }

    private func defaultAppIconImage() -> NSImage? {
        let fallbackName = Bundle.main.iconFileName ?? "AppIcon"
        return NSImage(named: fallbackName)
    }

    private func customIconImage(for icon: CustomAppIcon) -> NSImage? {
        NSImage(contentsOf: icon.fileURL)
    }

    private func appIconCard(title: String, image: NSImage?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : .clear)
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func handleIconDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let provider = matching else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in importCustomIcon(from: url) }
        }
        return true
    }

    private func importCustomIcon(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            iconImportError = "That file could not be loaded as an image."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let id = UUID()
        let fileName = "custom-icon-\(id.uuidString).\(ext)"
        let destination = CustomAppIcon.iconDirectory.appendingPathComponent(fileName)

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: [.atomic])
        } catch {
            iconImportError = "Unable to save the icon file."
            return
        }

        let newIcon = CustomAppIcon(id: id, name: name.isEmpty ? "Custom Icon" : name, fileName: fileName)
        if !customAppIcons.contains(newIcon) {
            customAppIcons.append(newIcon)
        }
        selectedAppIconID = newIcon.id.uuidString
        NSApp.applicationIconImage = image
        iconImportError = nil
    }

    private func removeCustomIcon(_ icon: CustomAppIcon) {
        if let index = customAppIcons.firstIndex(of: icon) {
            customAppIcons.remove(at: index)
        }
        if FileManager.default.fileExists(atPath: icon.fileURL.path) {
            try? FileManager.default.removeItem(at: icon.fileURL)
        }
        if selectedAppIconID == icon.id.uuidString {
            selectedAppIconID = nil
            applySelectedAppIcon()
        }
    }

    func checkVideoInput() -> Bool {
        if let _ = AVCaptureDevice.default(for: .video) {
            return true
        }

        return false
    }

    @ViewBuilder
    private func notchWidthControls() -> some View {
        Section {
            let recommendedMin = currentRecommendedMinimumNotchWidth()
            let tabCount = enabledStandardTabCount()
            let dynamicRange = Double(recommendedMin)...900
            
            let closedRange = Double(80)...400
            let minimalisticRange = Double(250)...600

            let widthBinding = Binding<Double>(
                get: { Double(openNotchWidth) },
                set: { newValue in
                    let clamped = min(max(newValue, dynamicRange.lowerBound), dynamicRange.upperBound)
                    let value = CGFloat(clamped)
                    if openNotchWidth != value {
                        openNotchWidth = value
                    }
                }
            )
            
            let closedWidthBinding = Binding<Double>(
                get: { Double(closedNotchWidth) },
                set: { newValue in
                    let clamped = min(max(newValue, closedRange.lowerBound), closedRange.upperBound)
                    let value = CGFloat(clamped)
                    if closedNotchWidth != value {
                        closedNotchWidth = value
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            )

            VStack(alignment: .leading, spacing: 10) {
                Defaults.Toggle(key: .customizePhysicalNotchWidth) {
                    Text("Customize physical notch width")
                }
                .onChange(of: customizePhysicalNotchWidth) {
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                .settingsHighlight(id: highlightID("Customize physical notch width"))
                
                Slider(
                    value: closedWidthBinding,
                    in: closedRange,
                    step: 5
                ) {
                    HStack {
                        Text("Closed notch / pill width")
                        Spacer()
                        Text("\(Int(closedNotchWidth)) px")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("Closed notch / pill width"))

                Divider().padding(.vertical, 4)

                Slider(
                    value: widthBinding,
                    in: dynamicRange,
                    step: 10
                ) {
                    HStack {
                        Text("Expanded notch width")
                        Spacer()
                        Text("\(Int(openNotchWidth)) px")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Expanded notch width"))

                HStack {
                    Text("\(tabCount) tab\(tabCount == 1 ? "" : "s") enabled · min \(Int(recommendedMin)) px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Width") {
                        openNotchWidth = recommendedMin
                    }
                    .disabled(abs(openNotchWidth - recommendedMin) < 0.5)
                    .buttonStyle(.bordered)
                }

                let description = enableMinimalisticUI
                ? String(localized: "Expanded width adjustments apply only to the standard notch layout. Disable Minimalistic UI to edit this value.")
                : String(localized: "Recommended minimum width adjusts automatically based on the number of enabled tabs.")

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                enforceMinimumNotchWidth()
            }
        } header: {
            HStack {
                Text("Notch Width")
                customBadge(text: "Beta")
            }
        }
    }

    private func enforceLockScreenGlassConsistency() {
        if lockScreenGlassStyle == .frosted && lockScreenGlassCustomizationMode != .standard {
            lockScreenGlassCustomizationMode = .standard
        }
        if lockScreenGlassCustomizationMode == .customLiquid && lockScreenGlassStyle != .liquid {
            lockScreenGlassStyle = .liquid
        }
    }
}

struct LockScreenSettings: View {
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenMusicLiquidGlassVariant) private var lockScreenMusicLiquidGlassVariant
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.lockScreenMusicFullscreenArtworkEnabled) private var lockScreenMusicFullscreenArtworkEnabled
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.lockScreenMusicMergedAirPlayOutput) private var lockScreenMusicMergedAirPlayOutput
    @ObservedObject private var musicManager = MusicManager.shared

    private var isAppleMusicActive: Bool {
        musicManager.bundleIdentifier == "com.apple.Music"
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.lockScreen.highlightID(for: title)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var musicVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenMusicLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenMusicLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableLockScreenLiveActivity) {
                    Text("Enable lock screen live activity")
                }
                .settingsHighlight(id: highlightID("Enable lock screen live activity"))
                Defaults.Toggle(key: .enableLockSounds) {
                    Text("Play lock/unlock sounds")
                }
                .settingsHighlight(id: highlightID("Play lock/unlock sounds"))
            } header: {
                Text("Live Activity & Feedback")
            } footer: {
                Text("Controls whether Dynamic Island mirrors lock/unlock events with its own live activity and audible chimes.")
            }

            Section {
                if #available(macOS 26.0, *) {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .settingsHighlight(id: highlightID("Material"))
                } else {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(true)
                    .settingsHighlight(id: highlightID("Material"))
                    Text("Liquid Glass requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if lockScreenGlassStyle == .liquid {
                    Picker("Glass mode", selection: $lockScreenGlassCustomizationMode) {
                        ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Glass mode"))

                    if lockScreenGlassCustomizationMode == .customLiquid {
                        Text("Use the sliders below to pick unique Apple liquid-glass variants for each widget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Custom Liquid settings require the Liquid Glass material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lock Screen Glass")
            } footer: {
                Text("Choose the global material mode for lock screen widgets. Custom Liquid unlocks per-widget variant sliders while Standard sticks to the classic frosted/liquid options.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenMediaWidget) {
                    Text("Show lock screen media panel")
                }
                .settingsHighlight(id: highlightID("Show lock screen media panel"))
                Defaults.Toggle(key: .lockScreenShowAppIcon) {
                    Text("Show media app icon")
                }
                .disabled(!enableLockScreenMediaWidget)
                .settingsHighlight(id: highlightID("Show media app icon"))
                if isAppleMusicActive {
                    Defaults.Toggle(key: .lockScreenMusicMergedAirPlayOutput) {
                        Text("Show merged AirPlay and output devices")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Show merged AirPlay and output devices"))
                }
                Defaults.Toggle(key: .lockScreenPanelShowsBorder) {
                    Text("Show panel border")
                }
                .disabled(!enableLockScreenMediaWidget)
                .settingsHighlight(id: highlightID("Show panel border"))
                if lockScreenGlassCustomizationMode == .customLiquid {
                    Defaults.Toggle(key: .lockScreenMusicUsesEnhancedLiquidBorder) {
                        Text("Use enhanced liquid border")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Use enhanced liquid border"))
                }
                if lockScreenGlassCustomizationMode == .customLiquid {
                    variantSlider(
                        title: "Music panel variant",
                        value: musicVariantBinding,
                        currentValue: lockScreenMusicLiquidGlassVariant.rawValue,
                        isEnabled: enableLockScreenMediaWidget,
                        highlight: highlightID("Music panel variant")
                    )
                } else if lockScreenGlassStyle == .frosted {
                    Defaults.Toggle(key: .lockScreenPanelUsesBlur) {
                        Text("Enable media panel blur")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else {
                    blurSettingUnavailableRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Defaults.Toggle(key: .lockScreenMusicFullscreenArtworkEnabled) {
                        Text("Fullscreen artwork on right-click")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Fullscreen artwork on right-click"))
                    Defaults.Toggle(key: .lockScreenUseArtworkLayoutOverFullscreenCanvas) {
                        Text("Use album art layout over fullscreen canvas")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Use album art layout over fullscreen canvas"))
                    Defaults.Toggle(key: .lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork) {
                        Text("Keep album art visible during fullscreen artwork")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Keep album art visible during fullscreen artwork"))
                    Text("Right-click the album art on the lock screen to set it as the wallpaper. Right-click again or click the background to restore the original wallpaper. If a canvas is available, Atoll can also keep the same album art + player layout on top of the live canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !showStandardMediaControls {
                    Text("Enable Dynamic Island media controls to manage the lock screen panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Media Panel")
            } footer: {
                Text("Enable and style the media controls that appear above the system clock when the screen is locked.")
            }
            .disabled(!showStandardMediaControls)
            .opacity(showStandardMediaControls ? 1 : 0.5)

            LockScreenPositioningControls()

            Section {
                Button("Copy Latest Crash Report") {
                    copyLatestCrashReport()
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Collect the latest crash report to share with the developer when reporting lock screen or overlay issues.")
            }
        }
        .onAppear(perform: enforceLockScreenGlassConsistency)
        .onChange(of: lockScreenGlassStyle) { _, _ in enforceLockScreenGlassConsistency() }
        .onChange(of: lockScreenGlassCustomizationMode) { _, _ in enforceLockScreenGlassConsistency() }
        .navigationTitle("Lock Screen")
    }
}

extension LockScreenSettings {
    private func enforceLockScreenGlassConsistency() {
        if lockScreenGlassStyle == .frosted && lockScreenGlassCustomizationMode != .standard {
            lockScreenGlassCustomizationMode = .standard
        }
        if lockScreenGlassCustomizationMode == .customLiquid && lockScreenGlassStyle != .liquid {
            lockScreenGlassStyle = .liquid
        }
    }

    private var blurSettingUnavailableRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Only available when Material is set to Frosted Glass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func variantSlider(
        title: String,
        value: Binding<Double>,
        currentValue: Int,
        isEnabled: Bool,
        highlight: String,
        preview: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("v\(currentValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: liquidVariantRange, step: 1)

            if let preview {
                preview
                    .padding(.top, 6)
            }
        }
        .settingsHighlight(id: highlight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct LockScreenGlassVariantPreviewCell: View {
    @Binding var variant: LiquidGlassVariant

    private let cornerRadius: CGFloat = 16
    private let previewCornerRadius: CGFloat = 14
    private let previewSize = CGSize(width: 190, height: 96)

    var body: some View {
        ZStack {
            Image("glassdesktop")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            liquidGlassPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 6)
        .allowsHitTesting(false)
        .onAppear {
            Logger.log("Lock screen glass preview appeared (variant v\(variant.rawValue))", category: .performance)
        }
        .onDisappear {
            Logger.log("Lock screen glass preview disappeared", category: .performance)
        }
        .onChange(of: variant) { _, newValue in
            Logger.log("Lock screen glass preview variant changed to v\(newValue.rawValue)", category: .performance)
        }
    }

    private var liquidGlassPreview: some View {
        LiquidGlassBackground(
            variant: variant,
            cornerRadius: previewCornerRadius
        ) {
            Color.white.opacity(0.04)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }
}

private struct LockScreenPositioningControls: View {
    @Default(.lockScreenMusicVerticalOffset) private var musicOffset
    @Default(.lockScreenMusicPanelWidth) private var musicWidth
    private let offsetRange: ClosedRange<Double> = -160...160
    private let musicWidthRange: ClosedRange<Double> = 320...Double(LockScreenMusicPanel.defaultCollapsedWidth)

    var body: some View {
        Section {
            let musicBinding = Binding<Double>(
                get: { musicOffset },
                set: { newValue in
                    let clampedValue = clampOffset(newValue)
                    if musicOffset != clampedValue {
                        musicOffset = clampedValue
                    }
                    propagateMusicOffsetChange(animated: false)
                }
            )

            let musicWidthBinding = Binding<Double>(
                get: { musicWidth },
                set: { newValue in
                    let clampedValue = clamp(newValue, within: musicWidthRange)
                    if musicWidth != clampedValue {
                        musicWidth = clampedValue
                        propagateMusicWidthChange(animated: false)
                    }
                }
            )

            LockScreenPositioningPreview(
                musicOffset: musicBinding,
                musicWidth: musicWidthBinding
            )
            .frame(height: 260)
            .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 24) {
                offsetColumn(
                    title: String(localized: "Music"),
                    value: musicOffset,
                    resetTitle: String(localized: "Reset Music"),
                    resetAction: resetMusicOffset
                )

                Spacer()
            }

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 16) {
                widthSlider(
                    title: String(localized: "Media Panel Width"),
                    value: musicWidthBinding,
                    range: musicWidthRange,
                    resetTitle: String(localized: "Reset Media Width"),
                    resetAction: resetMusicWidth,
                    helpText: String(localized: "Shrinks the lock screen media panel while keeping the expanded view full width.")
                )
            }
        } header: {
            Text("Lock Screen Positioning")
        } footer: {
            Text("Drag the preview to adjust vertical placement. Positive values lift the panel; negative values lower it. Use the width slider below to narrow the media panel without exceeding its default size. Changes apply instantly while the panel is visible.")
                .textCase(nil)
        }
    }

    private func clampOffset(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    private func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func resetMusicOffset() {
        musicOffset = 0
        propagateMusicOffsetChange(animated: true)
    }

    private func resetMusicWidth() {
        musicWidth = Double(LockScreenMusicPanel.defaultCollapsedWidth)
        propagateMusicWidthChange(animated: true)
    }

    private func propagateMusicOffsetChange(animated: Bool) {
        Task { @MainActor in
            LockScreenPanelManager.shared.applyOffsetAdjustment(animated: animated)
        }
    }

    private func propagateMusicWidthChange(animated: Bool) {
        Task { @MainActor in
            LockScreenPanelManager.shared.applyOffsetAdjustment(animated: animated)
        }
    }

    @ViewBuilder
    private func offsetColumn(title: String, value: Double, resetTitle: String, resetAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) Offset")
                .font(.subheadline.weight(.semibold))

            Text("\(formattedPoints(value)) pt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(resetTitle) {
                resetAction()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func widthSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        resetTitle: String,
        resetAction: @escaping () -> Void,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedWidth(value.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)

            HStack(alignment: .top) {
                Button(resetTitle) {
                    resetAction()
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func formattedPoints(_ value: Double) -> String {
        String(format: "%+.0f", value)
    }

    private func formattedWidth(_ value: Double) -> String {
        String(format: "%.0f pt", value)
    }
}

private struct LockScreenPositioningPreview: View {
    @Binding var musicOffset: Double
    @Binding var musicWidth: Double

    @State private var musicStartOffset: Double = 0
    @State private var isMusicDragging = false

    private let offsetRange: ClosedRange<Double> = -160...160

    var body: some View {
        GeometryReader { geometry in
            let screenPadding: CGFloat = 26
            let screenCornerRadius: CGFloat = 28
            let screenRect = CGRect(
                x: screenPadding,
                y: screenPadding,
                width: geometry.size.width - (screenPadding * 2),
                height: geometry.size.height - (screenPadding * 2)
            )
            let centerX = screenRect.midX
            let musicBaseY = screenRect.minY + (screenRect.height * 0.78)
            let defaultMusicWidth = Double(LockScreenMusicPanel.defaultCollapsedWidth)
            let musicWidthScale = CGFloat(musicWidth / defaultMusicWidth)
            let musicSize = CGSize(
                width: (screenRect.width * 0.56) * musicWidthScale,
                height: screenRect.height * 0.34
            )

            ZStack {
                RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                    .frame(width: screenRect.width, height: screenRect.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 18)
                    .position(x: screenRect.midX, y: screenRect.midY)

                musicPanel(size: musicSize)
                    .position(x: centerX, y: musicBaseY - CGFloat(musicOffset))
                    .gesture(musicDragGesture(in: screenRect, baseY: musicBaseY, panelSize: musicSize))
            }
        }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: musicOffset)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: musicWidth)
    }

    private func musicPanel(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.purple.opacity(0.68), Color.pink.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Media", systemImage: "play.square.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text("Lock screen panel preview")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(.horizontal, 18)
            }
            .shadow(color: Color.purple.opacity(0.24), radius: 12, x: 0, y: 9)
    }

    private func musicDragGesture(in screenRect: CGRect, baseY: CGFloat, panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isMusicDragging {
                    isMusicDragging = true
                    musicStartOffset = musicOffset
                }

                let proposed = musicStartOffset - Double(value.translation.height)
                musicOffset = clampedOffset(
                    proposed,
                    baseCenterY: baseY,
                    panelHeight: panelSize.height,
                    screenRect: screenRect
                )
            }
            .onEnded { _ in
                isMusicDragging = false
            }
    }

    private func clampedOffset(
        _ proposed: Double,
        baseCenterY: CGFloat,
        panelHeight: CGFloat,
        screenRect: CGRect
    ) -> Double {
        let halfHeight = panelHeight / 2
        let minCenterY = screenRect.minY + halfHeight
        let maxCenterY = screenRect.maxY - halfHeight
        let proposedCenter = baseCenterY - CGFloat(proposed)
        let clampedCenter = min(max(proposedCenter, minCenterY), maxCenterY)
        let derivedOffset = Double(baseCenterY - clampedCenter)
        return min(max(derivedOffset, offsetRange.lowerBound), offsetRange.upperBound)
    }
}

private func copyLatestCrashReport() {
    let crashReportsPath = NSString(string: "~/Library/Logs/DiagnosticReports").expandingTildeInPath
    let fileManager = FileManager.default

    do {
        let files = try fileManager.contentsOfDirectory(atPath: crashReportsPath)
        let crashFiles = files.filter { $0.contains("DynamicIsland") && $0.hasSuffix(".crash") }

        guard let latestCrash = crashFiles.sorted(by: >).first else {
            let alert = NSAlert()
            alert.messageText = "No Crash Reports Found"
            alert.informativeText = "No crash reports found for DynamicIsland"
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let crashPath = (crashReportsPath as NSString).appendingPathComponent(latestCrash)
        let crashContent = try String(contentsOfFile: crashPath, encoding: .utf8)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(crashContent, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Crash Report Copied"
        alert.informativeText = "Crash report '\(latestCrash)' has been copied to clipboard"
        alert.alertStyle = .informational
        alert.runModal()
    } catch {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = "Failed to read crash reports: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}

struct Shortcuts: View {
    @Default(.enableShortcuts) var enableShortcuts

    private func highlightID(_ title: String) -> String {
        SettingsTab.shortcuts.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableShortcuts) {
                    Text("Enable global keyboard shortcuts")
                }
                .settingsHighlight(id: highlightID("Enable global keyboard shortcuts"))
            } header: {
                Text("General")
            } footer: {
                Text("When disabled, all keyboard shortcuts will be inactive. You can still use the UI controls.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if enableShortcuts {
                Section {
                    KeyboardShortcuts.Recorder("Toggle Sneak Peek:", name: .toggleSneakPeek)
                        .disabled(!enableShortcuts)
                } header: {
                    Text("Media")
                } footer: {
                    Text("Sneak Peek shows the media title and artist under the notch for a few seconds.")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
                        .disabled(!enableShortcuts)
                } header: {
                    Text("Navigation")
                } footer: {
                    Text("Toggle the Dynamic Island open or closed from anywhere.")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keyboard shortcuts are disabled")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text("Enable global keyboard shortcuts above to customize your shortcuts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Shortcuts")
    }
}

func proFeatureBadge() -> some View {
    Text("Upgrade to Pro")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("Coming soon")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: String) -> some View {
    Text(LocalizedStringKey(text))
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: String, _ description: String) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(text)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct CustomOSDSettings: View {
    @Default(.enableCustomOSD) var enableCustomOSD
    @Default(.hasSeenOSDAlphaWarning) var hasSeenOSDAlphaWarning
    @Default(.enableOSDVolume) var enableOSDVolume
    @Default(.enableOSDBrightness) var enableOSDBrightness
    @Default(.enableOSDKeyboardBacklight) var enableOSDKeyboardBacklight
    @Default(.enableThirdPartyDDCIntegration) var enableThirdPartyDDCIntegration
    @Default(.osdMaterial) var osdMaterial
    @Default(.osdLiquidGlassCustomizationMode) var osdLiquidGlassCustomizationMode
    @Default(.osdLiquidGlassVariant) var osdLiquidGlassVariant
    @Default(.osdIconColorStyle) var osdIconColorStyle
    @Default(.enableSystemHUD) var enableSystemHUD
    @ObservedObject private var accessibilityPermission = AccessibilityPermissionStore.shared

    @State private var showAlphaWarning = false
    @State private var previewValue: CGFloat = 0.65
    @State private var previewType: SneakContentType = .volume

    private func highlightID(_ title: String) -> String {
        SettingsTab.hudAndOSD.highlightID(for: title)
    }

    private var hasAccessibilityPermission: Bool {
        accessibilityPermission.isAuthorized
    }

    private var availableOSDMaterials: [OSDMaterial] {
        if #available(macOS 26.0, *) {
            return OSDMaterial.allCases
        }
        return OSDMaterial.allCases.filter { $0 != .liquid }
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var osdLiquidVariantBinding: Binding<Double> {
        Binding(
            get: { Double(osdLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                osdLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    var body: some View {
        Form {
            if !hasAccessibilityPermission && !enableThirdPartyDDCIntegration {
                Section {
                    SettingsPermissionCallout(
                        message: "Accessibility permission is needed to intercept system controls for the Custom OSD.",
                        requestAction: { accessibilityPermission.requestAuthorizationPrompt() },
                        openSettingsAction: { accessibilityPermission.openSystemSettings() }
                    )
                } header: {
                    Text("Accessibility")
                }
            }

            if hasAccessibilityPermission || enableThirdPartyDDCIntegration {
                Section {
                    Toggle("Volume OSD", isOn: $enableOSDVolume)
                        .settingsHighlight(id: highlightID("Volume OSD"))
                    Toggle("Brightness OSD", isOn: $enableOSDBrightness)
                        .settingsHighlight(id: highlightID("Brightness OSD"))
                    Toggle("Keyboard Backlight OSD", isOn: $enableOSDKeyboardBacklight)
                        .settingsHighlight(id: highlightID("Keyboard Backlight OSD"))
                        .disabled(enableThirdPartyDDCIntegration)
                        .help(enableThirdPartyDDCIntegration ? "Disabled while external display integration is active \u{2014} brightness keys are handled by the external app." : "")
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Choose which system controls should display custom OSD windows.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    Picker("Material", selection: $osdMaterial) {
                        ForEach(availableOSDMaterials, id: \.self) { material in
                            Text(material.rawValue).tag(material)
                        }
                    }
                    .settingsHighlight(id: highlightID("Material"))
                    .onChange(of: osdMaterial) { _, _ in
                        previewValue = previewValue == 0.65 ? 0.651 : 0.65
                    }

                    if osdMaterial == .liquid {
                        if #available(macOS 26.0, *) {
                            Picker("Glass mode", selection: $osdLiquidGlassCustomizationMode) {
                                ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if osdLiquidGlassCustomizationMode == .customLiquid {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Custom liquid variant")
                                        Spacer()
                                        Text("v\(osdLiquidGlassVariant.rawValue)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(value: osdLiquidVariantBinding, in: liquidVariantRange, step: 1)
                                }
                            }
                        } else {
                            Text("Custom Liquid is available on macOS 26 or later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Icon & Progress Color", selection: $osdIconColorStyle) {
                        ForEach(OSDIconColorStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .settingsHighlight(id: highlightID("Icon & Progress Color"))
                    .onChange(of: osdIconColorStyle) { _, _ in
                        previewValue = previewValue == 0.65 ? 0.651 : 0.65
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Material Options:")
                        Text("• Frosted Glass: Translucent blur effect")
                        Text("• Liquid Glass: Modern glass effect (macOS 26+)")
                        Text("• Solid Dark/Light/Auto: Opaque backgrounds")
                        Text("")
                        Text("Color options control the icon and progress bar appearance. Auto adapts to system theme.")
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Text("Live Preview")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            CustomOSDView(
                                type: .constant(previewType),
                                value: .constant(previewValue),
                                icon: .constant("")
                            )
                            .frame(width: 200, height: 200)

                            HStack(spacing: 8) {
                                Button("Volume") {
                                    previewType = .volume
                                }
                                .buttonStyle(.bordered)

                                Button("Brightness") {
                                    previewType = .brightness
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Backlight") {
                                    previewType = .backlight
                                }
                                .buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                            
                            Slider(value: $previewValue, in: 0...1)
                                .frame(width: 160)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Adjust settings above to see changes in real-time. The actual OSD appears at the bottom center of your screen.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Custom OSD")
        .onAppear {
            accessibilityPermission.refreshStatus()
            if #unavailable(macOS 26.0), osdMaterial == .liquid {
                osdMaterial = .frosted
                osdLiquidGlassCustomizationMode = .standard
            }
        }
        .onChange(of: accessibilityPermission.isAuthorized) { _, granted in
            if !granted {
                enableCustomOSD = false
            }
        }
    }
}

struct SettingsPermissionCallout: View {
    let title: String
    let message: String
    let icon: String
    let iconColor: Color
    let requestButtonTitle: String
    let openSettingsButtonTitle: String
    let requestAction: () -> Void
    let openSettingsAction: () -> Void

    init(
        title: String = "Accessibility permission required",
        message: String,
        icon: String = "exclamationmark.triangle.fill",
        iconColor: Color = .orange,
        requestButtonTitle: String = "Request Access",
        openSettingsButtonTitle: String = "Open Settings",
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.iconColor = iconColor
        self.requestButtonTitle = requestButtonTitle
        self.openSettingsButtonTitle = openSettingsButtonTitle
        self.requestAction = requestAction
        self.openSettingsAction = openSettingsAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(iconColor)

            Text(LocalizedStringKey(message))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(LocalizedStringKey(requestButtonTitle)) {
                    requestAction()
                }
                .buttonStyle(.borderedProminent)

                Button(LocalizedStringKey(openSettingsButtonTitle)) {
                    openSettingsAction()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    HUD()
}

struct AppIconImage: View {
    let bundleIdentifiers: [String]
    var assetFallback: String? = nil
    var symbolFallback: String = "app.fill"
    var symbolColor: Color = .accentColor
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let nsImage = resolvedIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else if let assetFallback, let nsImage = NSImage(named: NSImage.Name(assetFallback)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                Image(systemName: symbolFallback)
                    .foregroundColor(symbolColor)
            }
        }
        .frame(width: size, height: size)
    }

    private func resolvedIcon() -> NSImage? {
        for bundleID in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                // NSWorkspace returns a valid icon even for generic apps;
                // resize to keep memory low.
                let thumb = NSImage(size: NSSize(width: 32, height: 32))
                thumb.lockFocus()
                icon.draw(in: NSRect(origin: .zero, size: NSSize(width: 32, height: 32)),
                          from: NSRect(origin: .zero, size: icon.size),
                          operation: .copy, fraction: 1.0)
                thumb.unlockFocus()
                return thumb
            }
        }
        return nil
    }
}

private struct QuickShareProviderIconImage: View {
    let provider: QuickShareProvider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                AppIconImage(
                    bundleIdentifiers: provider.bundleIdentifiersFallback,
                    assetFallback: provider.assetFallbackName,
                    symbolFallback: provider.symbolFallbackName,
                    symbolColor: .accentColor,
                    size: size
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private extension QuickShareProvider {
    var bundleIdentifiersFallback: [String] {
        switch id {
        case "LocalSend":
            return ["org.localsend.localsend_app", "org.localsend.localsend"]
        case "AirDrop":
            return ["com.apple.finder"]
        case "Mail":
            return ["com.apple.mail"]
        case "Messages":
            return ["com.apple.MobileSMS", "com.apple.iChat"]
        case "Notes":
            return ["com.apple.Notes"]
        case "Reminders":
            return ["com.apple.reminders"]
        case "Add to Safari Reading List":
            return ["com.apple.Safari"]
        default:
            return []
        }
    }

    var assetFallbackName: String? {
        id == "LocalSend" ? "LocalSend" : nil
    }

    var symbolFallbackName: String {
        id == "System Share Menu" ? "square.and.arrow.up.on.square" : "square.and.arrow.up"
    }
}
