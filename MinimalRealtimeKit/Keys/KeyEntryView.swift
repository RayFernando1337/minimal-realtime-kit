//  KeyEntryView.swift
//  T0.2 — a minimal, self-contained "API Keys" screen.
//
//  BYO-key UX: the user pastes their own key(s); each is stored ONLY in the Keychain (never
//  UserDefaults / a file). A "Forget" control removes it. The screen never reveals, logs, or
//  even previews a prefix of a stored key (invariant N1) — only a masked "stored / not stored"
//  indicator.
//
//  Two keys, two distinct Keychain accounts:
//    • OpenAI API key  — REQUIRED to connect the realtime voice session.
//    • EXA key         — OPTIONAL; enables the `web_search` tool (ExaWebSearchProvider). The app
//                        runs fine without it (web_search just answers "not configured").
//
//  Standalone: this view owns a small @Observable store and is not presented by App.swift /
//  RootView.swift here — a later screen wires it into navigation.

import SwiftUI

// MARK: - Store

@MainActor
@Observable
final class KeyEntryStore {
    // ── OpenAI (required) ──
    /// Bound to the OpenAI SecureField. Held only in memory while the screen is open; cleared on save.
    var draft: String = ""
    /// Whether an OpenAI key currently lives in the Keychain (drives the masked indicator).
    private(set) var hasStoredKey: Bool
    /// Last OpenAI outcome. Never contains any part of a key.
    private(set) var status: Status = .idle

    // ── EXA (optional — powers web_search via ExaWebSearchProvider) ──
    /// Bound to the EXA SecureField. Held only in memory while the screen is open; cleared on save.
    var exaDraft: String = ""
    /// Whether an EXA key currently lives in the Keychain (drives the masked indicator).
    private(set) var hasStoredExaKey: Bool
    /// Last EXA outcome. Never contains any part of a key.
    private(set) var exaStatus: Status = .idle

    enum Status: Equatable {
        case idle
        case saved
        case forgotten
        case invalid(String)
    }

    init() {
        hasStoredKey = KeychainStore.hasValue()
        hasStoredExaKey = KeychainStore.hasValue(account: KeychainStore.exaKeyAccount)
    }

    // MARK: OpenAI key

    /// True when the current OpenAI draft would pass validation.
    var canSave: Bool { Self.validationProblem(draft) == nil }

    func save() {
        if let problem = Self.validationProblem(draft) {
            status = .invalid(problem)
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(trimmed)
            draft = ""
            status = .saved
            hasStoredKey = KeychainStore.hasValue()
        } catch {
            // Surface a generic failure — never echo the key or the underlying status code.
            status = .invalid("Couldn't save to the Keychain. Please try again.")
        }
    }

    func forget() {
        KeychainStore.delete()
        draft = ""
        status = .forgotten
        hasStoredKey = KeychainStore.hasValue()
    }

    // MARK: EXA key (optional)

    /// True when the current EXA draft would pass validation. (The EXA key is OPTIONAL, so an
    /// empty field is a fine resting state — it just keeps Save disabled, it's never an error.)
    var canSaveExa: Bool { Self.exaValidationProblem(exaDraft) == nil }

    func saveExa() {
        if let problem = Self.exaValidationProblem(exaDraft) {
            exaStatus = .invalid(problem)
            return
        }
        let trimmed = exaDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(trimmed, account: KeychainStore.exaKeyAccount)
            exaDraft = ""
            exaStatus = .saved
            hasStoredExaKey = KeychainStore.hasValue(account: KeychainStore.exaKeyAccount)
        } catch {
            exaStatus = .invalid("Couldn't save to the Keychain. Please try again.")
        }
    }

    func forgetExa() {
        KeychainStore.delete(account: KeychainStore.exaKeyAccount)
        exaDraft = ""
        exaStatus = .forgotten
        hasStoredExaKey = KeychainStore.hasValue(account: KeychainStore.exaKeyAccount)
    }

    // MARK: Validation

    /// Returns a human-readable problem if the OpenAI input is unusable, or nil if it looks like a
    /// real key. Rejects empty/whitespace-only input and obvious un-filled placeholders.
    static func validationProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter your OpenAI API key."
        }
        if trimmed.hasPrefix("<<") || trimmed.hasPrefix("REPLACE_") {
            return "That looks like a placeholder, not a real key."
        }
        return nil
    }

    /// Same shape as `validationProblem`, tuned for the OPTIONAL EXA key: an empty field is a valid
    /// "skip web search" state (Save stays disabled, no error shown), placeholders are rejected.
    static func exaValidationProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter your EXA key, or leave this blank to skip web search."
        }
        if trimmed.hasPrefix("<<") || trimmed.hasPrefix("REPLACE_") {
            return "That looks like a placeholder, not a real key."
        }
        return nil
    }
}

// MARK: - View

struct KeyEntryView: View {
    @State private var store = KeyEntryStore()
    @FocusState private var focusedField: Field?

    private enum Field { case openAI, exa }

    var body: some View {
        Form {
            // ── OpenAI API key (required) ──
            Section {
                storedIndicator(
                    hasKey: store.hasStoredKey,
                    storedTitle: "Key stored",
                    emptyTitle: "No key stored",
                    emptySubtitle: "Paste your OpenAI API key to connect."
                )
            }

            Section {
                SecureField("Paste your OpenAI key (sk-\u{2026})", text: $store.draft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .openAI)
                    .onSubmit { store.save() }

                Button("Save key") {
                    focusedField = nil
                    store.save()
                }
                .disabled(!store.canSave)

                Link("Get a key at platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.callout)

                if store.hasStoredKey {
                    Button("Forget key", role: .destructive) {
                        focusedField = nil
                        store.forget()
                    }
                }
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Your key is stored only in this device's Keychain and is used directly to connect to OpenAI. It never leaves your device and is never shown again here.")
            }

            if let message = statusMessage(for: store.status) {
                Section { statusLabel(message) }
            }

            // ── Web search (optional, EXA-backed) ──
            Section {
                storedIndicator(
                    hasKey: store.hasStoredExaKey,
                    storedTitle: "Web search enabled",
                    emptyTitle: "Web search off",
                    emptySubtitle: "Paste an EXA key to let the agent search the live web."
                )
            }

            Section {
                SecureField("Paste your EXA key", text: $store.exaDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .exa)
                    .onSubmit { store.saveExa() }

                Button("Save EXA key") {
                    focusedField = nil
                    store.saveExa()
                }
                .disabled(!store.canSaveExa)

                Link("Get a key at dashboard.exa.ai", destination: URL(string: "https://dashboard.exa.ai/api-keys")!)
                    .font(.callout)

                if store.hasStoredExaKey {
                    Button("Forget EXA key", role: .destructive) {
                        focusedField = nil
                        store.forgetExa()
                    }
                }
            } header: {
                Text("Web search (optional)")
            } footer: {
                Text("Optional. Add an EXA key to enable the web_search tool — calls go directly to api.exa.ai. Stored only in this device's Keychain, never shown again, and never required to use the app.")
            }

            if let message = statusMessage(for: store.exaStatus) {
                Section { statusLabel(message) }
            }
        }
        .navigationTitle("API Keys")
    }

    // MARK: Pieces

    @ViewBuilder
    private func storedIndicator(
        hasKey: Bool,
        storedTitle: String,
        emptyTitle: String,
        emptySubtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hasKey ? "lock.fill" : "lock.open")
                .font(.title3)
                .foregroundStyle(hasKey ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasKey ? storedTitle : emptyTitle)
                    .font(.headline)
                Text(hasKey ? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  (hidden, on this device)"
                            : emptySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func statusMessage(for status: KeyEntryStore.Status) -> (text: String, symbol: String, tint: Color)? {
        switch status {
        case .idle:
            return nil
        case .saved:
            return ("Key saved to the Keychain.", "checkmark.seal.fill", .green)
        case .forgotten:
            return ("Key removed from this device.", "trash", .secondary)
        case .invalid(let problem):
            return (problem, "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder
    private func statusLabel(_ message: (text: String, symbol: String, tint: Color)) -> some View {
        Label(message.text, systemImage: message.symbol)
            .foregroundStyle(message.tint)
            .font(.callout)
    }
}

#Preview {
    NavigationStack {
        KeyEntryView()
    }
}
