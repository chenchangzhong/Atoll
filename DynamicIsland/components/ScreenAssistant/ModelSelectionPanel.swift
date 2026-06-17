/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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

import AppKit
import SwiftUI
import Defaults

private func applyModelSelectionCornerMask(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = NSColor.clear.cgColor
    if #available(macOS 13.0, *) {
        view.layer?.cornerCurve = .continuous
    }
}

// MARK: - Model Selection Panel
class ModelSelectionPanel: NSPanel {

    static func open() {
        if let existing = NSApp.windows.first(where: { $0 is ModelSelectionPanel }) {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = ModelSelectionPanel()
        panel.positionInCenter()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        setupWindow()
        setupContentView()
    }

    override var canBecomeKey: Bool {
        return true  // Can receive focus for interaction
    }

    override var canBecomeMain: Bool {
        return true
    }

    // Handle ESC key globally for the panel
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    private func setupWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true  // Enable dragging
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true

        styleMask.insert(.fullSizeContentView)

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]

        ScreenCaptureVisibilityManager.shared.register(self, scope: .panelsOnly)

        acceptsMouseMovedEvents = true
    }

    private func setupContentView() {
        let contentView = ModelSelectionView()
        let hostingView = NSHostingView(rootView: contentView)
        applyModelSelectionCornerMask(hostingView, radius: 16)
        self.contentView = hostingView

        // Set size for model selection panel
        let preferredSize = CGSize(width: 450, height: 600)
        hostingView.setFrameSize(preferredSize)
        setContentSize(preferredSize)
    }

    func positionInCenter() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = frame

        // Position in the center of the screen
        let xPosition = (screenFrame.width - panelFrame.width) / 2 + screenFrame.minX
        let yPosition = (screenFrame.height - panelFrame.height) / 2 + screenFrame.minY

        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }

    deinit {
        ScreenCaptureVisibilityManager.shared.unregister(self)
    }
}

// MARK: - Model Selection View
struct ModelSelectionView: View {
    private let primaryProviders: [AIModelProvider] = [.local, .custom]
    @State private var selectedProvider: AIModelProvider = Defaults[.selectedAIProvider]
    @State private var selectedModel: AIModel? = Defaults[.selectedAIModel]
    @State private var enableThinking: Bool = Defaults[.enableThinkingMode]

    // API Keys
    @State private var localEndpoint: String = Defaults[.localModelEndpoint]
    @State private var customApiKey: String = Defaults[.customApiKey]
    @State private var customEndpoint: String = Defaults[.customEndpoint]

    @State private var showingApiKeyAlert = false

    var body: some View {
        VStack(spacing: 0.0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Model Selection")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("Choose your preferred AI model and configuration")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: closePanel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.gray.opacity(0.05))

            Divider()

            // Content
            ScrollView(.vertical) {
                VStack(spacing: 24) {
                    // Provider Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI Provider")
                            .font(.headline)
                            .foregroundColor(.primary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                            ForEach(primaryProviders) { provider in
                                ProviderCard(
                                    provider: provider,
                                    isSelected: selectedProvider == provider,
                                    onSelect: { selectProvider(provider) }
                                )
                            }
                        }
                    }

                    Divider()

                    // Model Selection
                    if !selectedProvider.supportedModels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("\(selectedProvider.displayName) Models")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Spacer()

                                if selectedProvider == .custom || selectedProvider == .local {
                                    Button(action: addCustomModel) {
                                        Image(systemName: "plus.circle")
                                            .foregroundColor(.blue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Add model")
                                }
                            }

                            VStack(spacing: 8) {
                                ForEach(selectedProvider.supportedModels) { model in
                                    HStack(spacing: 4) {
                                        ModelRow(
                                            model: model,
                                            isSelected: selectedModel?.id == model.id,
                                            onSelect: { selectedModel = model }
                                        )

                                        if selectedProvider == .custom || selectedProvider == .local {
                                            Button(action: { removeCustomModel(model) }) {
                                                Image(systemName: "minus.circle")
                                                    .foregroundColor(.red)
                                                    .font(.caption)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .help("Remove model")
                                            .padding(.trailing, 4)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Thinking Mode Toggle
                    if selectedModel?.supportsThinking == true {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Reasoning Mode")
                                .font(.headline)
                                .foregroundColor(.primary)

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Enable Thinking Mode")
                                        .font(.body)
                                        .foregroundColor(.primary)

                                    Text("Shows the model's reasoning process before the final answer")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Toggle("", isOn: $enableThinking)
                                    .toggleStyle(SwitchToggleStyle())
                            }
                            .padding(16)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }

                    Divider()

                    // API Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        Text("API Configuration")
                            .font(.headline)
                            .foregroundColor(.primary)

                        ApiConfigurationSection(
                            provider: selectedProvider,
                            localEndpoint: $localEndpoint,
                            customApiKey: $customApiKey,
                            customEndpoint: $customEndpoint
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Divider()

            // Footer with Save/Cancel buttons
            HStack {
                Button("Cancel") {
                    closePanel()
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button("Save Configuration") {
                    saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConfigurationValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(ModelSelectionVisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            loadCurrentConfiguration()
        }
    }

    var isConfigurationValid: Bool {
        switch selectedProvider {
        case .local:
            return !localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .custom:
            return !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private func loadCurrentConfiguration() {
        selectedProvider = Defaults[.selectedAIProvider]
        selectedModel = Defaults[.selectedAIModel]
        ensureValidModelSelection()
        enableThinking = Defaults[.enableThinkingMode]

        localEndpoint = Defaults[.localModelEndpoint]
        customApiKey = Defaults[.customApiKey]
        customEndpoint = Defaults[.customEndpoint]
    }

    private func addCustomModel() {
        // Simple alert-based input for model ID and name
        let alert = NSAlert()
        alert.messageText = "Add Custom Model"
        alert.informativeText = "Enter the model ID as required by your API endpoint."

        let idField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        idField.placeholderString = "Model ID (e.g. gpt-4o-mini)"
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "Display Name (e.g. GPT-4o Mini)"

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.addArrangedSubview(idField)
        stackView.addArrangedSubview(nameField)

        alert.accessoryView = stackView
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = "\r"

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let modelId = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty else { return }

            let newModel = AIModel(
                id: modelId,
                name: modelName.isEmpty ? modelId : modelName,
                supportsThinking: false
            )

            var models = currentModels()
            // Avoid duplicates
            if !models.contains(where: { $0.id == modelId }) {
                models.append(newModel)
                saveModels(models)
                // Auto-select the new model
                selectedModel = newModel
            }
        }
    }

    private func removeCustomModel(_ model: AIModel) {
        let models = currentModels().filter { $0.id != model.id }
        saveModels(models)

        // If the removed model was selected, select another
        if selectedModel?.id == model.id {
            selectedModel = models.first
        }
    }

    private func currentModels() -> [AIModel] {
        switch selectedProvider {
        case .local: return Defaults[.localAIModels]
        case .custom: return Defaults[.customAIModels]
        default:
            print("⚠️ currentModels() called for unsupported provider: \(selectedProvider)")
            return []
        }
    }

    private func saveModels(_ models: [AIModel]) {
        switch selectedProvider {
        case .local: Defaults[.localAIModels] = models
        case .custom: Defaults[.customAIModels] = models
        default: break
        }
    }

    private func saveConfiguration() {
        ensureValidModelSelection()

        Defaults[.selectedAIProvider] = selectedProvider
        Defaults[.selectedAIModel] = selectedModel
        Defaults[.enableThinkingMode] = enableThinking

        Defaults[.localModelEndpoint] = localEndpoint
        Defaults[.customApiKey] = customApiKey
        Defaults[.customEndpoint] = customEndpoint

        closePanel()

        // Notify that configuration changed
        NotificationCenter.default.post(name: .aiModelConfigurationChanged, object: nil)
    }

    private func selectProvider(_ provider: AIModelProvider) {
        selectedProvider = provider
        ensureValidModelSelection()
    }

    private func ensureValidModelSelection() {
        if selectedModel == nil || !selectedProvider.supportedModels.contains(where: { $0.id == selectedModel?.id }) {
            selectedModel = selectedProvider.supportedModels.first
        }
    }

    private func closePanel() {
        if let window = NSApp.windows.first(where: { $0 is ModelSelectionPanel }) {
            window.close()
        }
    }
}

// MARK: - Provider Card
struct ProviderCard: View {
    private let wideCardMinHeight: CGFloat = 110
    let provider: AIModelProvider
    let isSelected: Bool
    let onSelect: () -> Void
    var isWide: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: iconForProvider(provider))
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .primary)
            }

            // Name and description
            VStack(spacing: 4) {
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(provider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                )
        )
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .frame(maxWidth: .infinity, minHeight: isWide ? wideCardMinHeight : nil)
    }

    private func iconForProvider(_ provider: AIModelProvider) -> String {
        switch provider {
        case .gemini: return "sparkles"
        case .openai: return "brain.head.profile"
        case .claude: return "doc.text"
        case .local: return "server.rack"
        case .groq: return "bolt.fill"
        case .custom: return "gearshape"
        }
    }
}

// MARK: - Model Row
struct ModelRow: View {
    let model: AIModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.body)
                    .foregroundColor(.primary)

                if model.supportsThinking {
                    Text("Supports reasoning mode")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
            } else {
                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - API Configuration Section
struct ApiConfigurationSection: View {
    let provider: AIModelProvider
    @Binding var localEndpoint: String
    @Binding var customApiKey: String
    @Binding var customEndpoint: String

    var body: some View {
        VStack(spacing: 12) {
            switch provider {
            case .local:
                ApiKeyField(
                    title: "Local Endpoint",
                    placeholder: "http://localhost:11434",
                    value: $localEndpoint,
                    helpText: "Ollama or compatible API endpoint",
                    isSecure: false
                )
            case .custom:
                ApiKeyField(
                    title: "Custom Endpoint",
                    placeholder: "https://api.openai.com/v1",
                    value: $customEndpoint,
                    helpText: "OpenAI-compatible API endpoint URL",
                    isSecure: false
                )
                ApiKeyField(
                    title: "Custom API Key",
                    placeholder: "Enter your API key (optional)",
                    value: $customApiKey,
                    helpText: "API key for authentication (leave empty for no auth)"
                )
            case .gemini, .openai, .claude, .groq:
                Group {
                    EmptyView()
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - API Key Field
struct ApiKeyField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let helpText: String
    var isSecure: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            if isSecure {
                SecureField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            Text(helpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Visual Effect View
struct ModelSelectionVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Notification Extension
extension Notification.Name {
    static let aiModelConfigurationChanged = Notification.Name("aiModelConfigurationChanged")
}
