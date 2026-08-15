//
//  ClaudeSettings.swift
//  ArchiverLib
//

import ClaudeExtractorStore
import ComposableArchitecture
import Shared
import SwiftUI

@Reducer
struct ClaudeSettings {
    static let maxCustomPromptLength = 1000

    @ObservableState
    struct State: Equatable {
        @Shared(.claudeEnabled)
        var claudeEnabled: Bool

        @Shared(.claudeCustomPrompt)
        var customPrompt: String?

        @Shared(.claudeModel)
        var claudeModelRawValue: String?

        var hasApiKey = false
        var apiKeyInput = ""
        var isValidatingApiKey = false
        var apiKeyValidationFailed = false

        var selectedModel: ClaudeModel {
            claudeModelRawValue.flatMap(ClaudeModel.init(rawValue:)) ?? .default
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case apiKeyStatusLoaded(Bool)
        case apiKeyValidated(Bool)
        case onAppear
        case onModelSelected(ClaudeModel)
        case onRemoveApiKeyTapped
        case onSaveApiKeyTapped
    }

    @Dependency(\.claudeExtractorStore) var claudeExtractorStore

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case let .apiKeyStatusLoaded(hasApiKey):
                state.hasApiKey = hasApiKey
                return .none

            case let .apiKeyValidated(isValid):
                state.isValidatingApiKey = false
                state.apiKeyValidationFailed = !isValid
                if isValid {
                    state.hasApiKey = true
                    state.apiKeyInput = ""
                } else {
                    // Do not keep an invalid key around
                    state.hasApiKey = false
                    return .run { _ in
                        await claudeExtractorStore.setApiKey(nil)
                    }
                }
                return .none

            case .onAppear:
                return .run { send in
                    let isConfigured = await claudeExtractorStore.isConfigured()
                    await send(.apiKeyStatusLoaded(isConfigured))
                }

            case let .onModelSelected(model):
                state.$claudeModelRawValue.withLock { $0 = model.rawValue }
                return .none

            case .onRemoveApiKeyTapped:
                state.hasApiKey = false
                state.apiKeyValidationFailed = false
                state.$claudeEnabled.withLock { $0 = false }
                return .run { _ in
                    await claudeExtractorStore.setApiKey(nil)
                }

            case .onSaveApiKeyTapped:
                let apiKey = state.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apiKey.isEmpty else { return .none }
                state.isValidatingApiKey = true
                state.apiKeyValidationFailed = false
                return .run { send in
                    await claudeExtractorStore.setApiKey(apiKey)
                    let isValid = await claudeExtractorStore.validateStoredApiKey()
                    await send(.apiKeyValidated(isValid))
                }
            }
        }
    }
}

struct ClaudeSettingsView: View {
    @Bindable var store: StoreOf<ClaudeSettings>

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Claude", bundle: #bundle)
                            .font(.headline)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                    }
                }

                LabeledContent(String(localized: "Status", bundle: #bundle)) {
                    statusView
                }

                if store.hasApiKey {
                    Toggle(
                        String(localized: "Use Claude", bundle: #bundle),
                        isOn: Binding(store.$claudeEnabled)
                    )
                }
            } footer: {
                Text("When enabled, Claude will suggest descriptions and tags for your documents. The document text is sent to the Anthropic API for analysis - only enable this if you are comfortable sharing document contents with Anthropic. Apple Intelligence is preferred when it is available and enabled.\nIn case of a failure, the non-AI version will always be used.", bundle: #bundle)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section {
                SecureField(String(localized: "API Key", bundle: #bundle),
                            text: $store.apiKeyInput,
                            prompt: Text(verbatim: "sk-ant-..."))
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif

                if store.isValidatingApiKey {
                    HStack {
                        Text("Validating API Key...", bundle: #bundle)
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    Button {
                        store.send(.onSaveApiKeyTapped)
                    } label: {
                        Text("Save API Key", bundle: #bundle)
                    }
                    .disabled(store.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if store.apiKeyValidationFailed {
                    Label {
                        Text("The API key was rejected by the Anthropic API.", bundle: #bundle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .font(.footnote)
                }

                if store.hasApiKey {
                    Button(role: .destructive) {
                        store.send(.onRemoveApiKeyTapped)
                    } label: {
                        Text("Remove API Key", bundle: #bundle)
                    }
                }
            } footer: {
                Text("You need an Anthropic API key to use Claude. Create one at console.anthropic.com. The key is stored securely in the Keychain and never leaves your device except for requests to the Anthropic API. API usage is billed by Anthropic to your account.", bundle: #bundle)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            if store.hasApiKey {
                Section {
                    Picker(String(localized: "Model", bundle: #bundle), selection: Binding(
                        get: { store.selectedModel },
                        set: { store.send(.onModelSelected($0)) }
                    )) {
                        ForEach(ClaudeModel.allCases) { model in
                            modelLabel(model)
                                .tag(model)
                        }
                    }
                }

                Section {
                    TextField(String(localized: "Custom Prompt", bundle: #bundle),
                              text: Binding(
                                get: { store.customPrompt ?? "" },
                                set: { newValue in
                                    let trimmed = String(newValue.prefix(ClaudeSettings.maxCustomPromptLength))
                                    store.$customPrompt.withLock { $0 = trimmed.isEmpty ? nil : trimmed }
                                }
                              ),
                              prompt: Text("Optional: Enter your custom prompt additions", bundle: #bundle),
                              axis: .vertical)
                    .lineLimit(1...)
                } footer: {
                    Text(verbatim: "\(store.customPrompt?.count ?? 0) / \(ClaudeSettings.maxCustomPromptLength)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .foregroundStyle(.primary)
        .onAppear {
            store.send(.onAppear)
        }
    }

    private func modelLabel(_ model: ClaudeModel) -> Text {
        switch model {
        case .opus:
            Text("Claude Opus (best quality)", bundle: #bundle)

        case .haiku:
            Text("Claude Haiku (fast & cheap)", bundle: #bundle)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if store.hasApiKey {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("API Key Configured", bundle: #bundle)
                    .font(.subheadline)
            }
            .foregroundStyle(.green)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "key.slash")
                Text("No API Key", bundle: #bundle)
                    .font(.subheadline)
            }
            .foregroundStyle(.orange)
        }
    }
}

#Preview("ClaudeSettings", traits: .fixedLayout(width: 800, height: 600)) {
    ClaudeSettingsView(
        store: Store(
            initialState: ClaudeSettings.State()
        ) {
            ClaudeSettings()
        } withDependencies: {
            $0.claudeExtractorStore = .previewValue
        }
    )
}
