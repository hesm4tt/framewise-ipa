import SwiftUI

struct AIScanSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ScanAISettings.enabledDefaultsKey) private var isEnabled = false
    @AppStorage(ScanAISettings.selectedProviderDefaultsKey) private var selectedProviderRaw = ScanAIProvider.openRouter.rawValue
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var isTestingKey = false
    @State private var connectionMessage: String?

    private var provider: ScanAIProvider {
        ScanAIProvider(rawValue: selectedProviderRaw) ?? .openRouter
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("AI provider", selection: $selectedProviderRaw) {
                        ForEach(ScanAIProvider.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .disabled(isTestingKey)

                    Toggle("Use \(provider.displayName) for scans", isOn: $isEnabled)
                        .disabled(!hasSavedKey || isTestingKey)

                    Text(hasSavedKey
                         ? "When enabled, each scan sends one reduced camera frame to \(provider.displayName) for subject detection. Failed requests fall back to on-device detection."
                         : "Add your own \(provider.displayName) API key below to enable cloud subject detection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AI scanning")
                } footer: {
                    Text("Each provider uses its own API key and account limits. Switching providers changes which saved key is used.")
                }

                Section {
                    SecureField(hasSavedKey ? "Replace saved key" : "\(provider.displayName) API key", text: $apiKeyInput)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save key to this iPhone") {
                        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty, ScanAISettings.saveAPIKey(key, for: provider) else {
                            connectionMessage = "Could not save the key in Keychain. Try again."
                            return
                        }
                        apiKeyInput = ""
                        hasSavedKey = true
                        connectionMessage = "\(provider.displayName) key saved securely on this iPhone."
                        AppDiagnostics.shared.log(provider.diagnosticArea, "User saved an API key to Keychain")
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingKey)

                    if hasSavedKey {
                        Button("Test saved key") { testKey() }
                            .disabled(isTestingKey)
                        Button("Forget saved key", role: .destructive) {
                            guard ScanAISettings.deleteAPIKey(for: provider) else {
                                connectionMessage = "Could not remove the saved key. Try again."
                                return
                            }
                            isEnabled = false
                            hasSavedKey = false
                            connectionMessage = "Saved \(provider.displayName) key removed."
                            AppDiagnostics.shared.log(provider.diagnosticArea, "User removed the saved API key")
                        }
                        .disabled(isTestingKey)
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
                    Text("Your \(provider.displayName) key")
                } footer: {
                    Link("Create or manage a key at \(provider.displayName)", destination: provider.keyURL)
                }

                Section {
                    HStack(alignment: .top) {
                        Text("Model")
                        Spacer(minLength: 12)
                        Text(provider.modelID)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    Text("Model availability, quotas, and any usage charges are controlled by \(provider.displayName). Check its current plan before enabling cloud scans.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Only the reduced scan frame is sent. The full-resolution photo stays on this iPhone. \(provider.dataPolicyNote)")
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
        .onAppear { refreshKeyState() }
        .onChange(of: selectedProviderRaw) { _ in
            apiKeyInput = ""
            connectionMessage = nil
            refreshKeyState()
            if isEnabled && !hasSavedKey {
                isEnabled = false
            }
        }
        .onChange(of: isEnabled) { enabled in
            AppDiagnostics.shared.log(provider.diagnosticArea, enabled ? "Cloud scans enabled" : "Cloud scans disabled")
        }
        .preferredColorScheme(.dark)
    }

    private func refreshKeyState() {
        hasSavedKey = ScanAISettings.hasSavedAPIKey(for: provider)
    }

    private func testKey() {
        let testedProvider = provider
        guard let key = ScanAISettings.savedAPIKey(for: testedProvider) else { return }
        isTestingKey = true
        connectionMessage = nil
        CloudVisionScanner.validateKey(key, for: testedProvider) { result in
            DispatchQueue.main.async {
                isTestingKey = false
                switch result {
                case .success:
                    connectionMessage = "\(testedProvider.displayName) accepted this key."
                    AppDiagnostics.shared.log(testedProvider.diagnosticArea, "API key validation succeeded")
                case let .failure(error):
                    connectionMessage = "Key check failed (\(error.diagnosticCode)). Check the key and connection."
                    AppDiagnostics.shared.log(testedProvider.diagnosticArea, "API key validation failed · code=\(error.diagnosticCode)")
                }
            }
        }
    }
}
