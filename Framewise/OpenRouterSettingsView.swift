import SwiftUI

struct OpenRouterSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OpenRouterPreferences.enabledDefaultsKey) private var isEnabled = false
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var isTestingKey = false
    @State private var connectionMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Use OpenRouter for scans", isOn: $isEnabled)
                        .disabled(!hasSavedKey)
                    Text(hasSavedKey
                         ? "When enabled, each scan sends one reduced camera frame to OpenRouter for subject detection."
                         : "Add your own OpenRouter API key to enable cloud subject detection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AI scanning")
                }

                Section {
                    SecureField(hasSavedKey ? "Replace saved key" : "OpenRouter API key", text: $apiKeyInput)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save key to this iPhone") {
                        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty, OpenRouterPreferences.saveAPIKey(key) else {
                            connectionMessage = "Could not save the key in Keychain. Try again."
                            return
                        }
                        apiKeyInput = ""
                        hasSavedKey = true
                        connectionMessage = "Key saved securely on this iPhone."
                        AppDiagnostics.shared.log("openrouter", "User saved an API key to Keychain")
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasSavedKey {
                        Button("Test saved key") { testKey() }
                            .disabled(isTestingKey)
                        Button("Forget saved key", role: .destructive) {
                            guard OpenRouterPreferences.deleteAPIKey() else {
                                connectionMessage = "Could not remove the saved key. Try again."
                                return
                            }
                            isEnabled = false
                            hasSavedKey = false
                            connectionMessage = "Saved key removed."
                            AppDiagnostics.shared.log("openrouter", "User removed the saved API key")
                        }
                    }

                    if isTestingKey {
                        HStack(spacing: 9) {
                            ProgressView()
                            Text("Checking key…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let connectionMessage {
                        Text(connectionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your OpenRouter key")
                } footer: {
                    Link("Create or manage a key at openrouter.ai", destination: URL(string: "https://openrouter.ai/keys")!)
                }

                Section {
                    HStack(alignment: .top) {
                        Text("Model")
                        Spacer(minLength: 12)
                        Text(OpenRouterScanner.modelID)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    Text("Framewise is pinned to this free vision model and does not fall back to paid models. Free model availability and request limits are controlled by OpenRouter; if it is unavailable, local subject detection runs instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Only the reduced scan frame is sent. Your full-resolution photo stays on this iPhone. OpenRouter and the model provider process the scan under their own service policies.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Cost and privacy")
                }
            }
            .navigationTitle("AI scan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { hasSavedKey = OpenRouterPreferences.hasSavedAPIKey() }
        .preferredColorScheme(.dark)
    }

    private func testKey() {
        guard let key = OpenRouterPreferences.savedAPIKey() else { return }
        isTestingKey = true
        connectionMessage = nil
        OpenRouterScanner.validateKey(key) { result in
            DispatchQueue.main.async {
                isTestingKey = false
                switch result {
                case .success:
                    connectionMessage = "OpenRouter accepted this key."
                    AppDiagnostics.shared.log("openrouter", "API key validation succeeded")
                case let .failure(error):
                    connectionMessage = "Key check failed (\(error.diagnosticCode)). Check the key and connection."
                    AppDiagnostics.shared.log("openrouter", "API key validation failed · code=\(error.diagnosticCode)")
                }
            }
        }
    }
}
