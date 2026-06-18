//  KeyEntryView.swift
//  T0.2 — a minimal, self-contained "Enter your OpenAI API key" screen.
//
//  BYO-key UX: the user pastes their own key; it is stored ONLY in the Keychain (never
//  UserDefaults / a file). A "Forget key" control removes it. The screen never reveals,
//  logs, or even previews a prefix of the stored key (invariant N1) — it only shows a
//  masked "stored / not stored" indicator.
//
//  Standalone: this view owns a small @Observable store and is not presented by App.swift /
//  RootView.swift here — a later screen wires it into navigation.

import SwiftUI

// MARK: - Store

@MainActor
@Observable
final class KeyEntryStore {
    /// Bound to the SecureField. Held only in memory while the screen is open; cleared on save.
    var draft: String = ""

    /// Whether a key currently lives in the Keychain (drives the masked indicator).
    private(set) var hasStoredKey: Bool

    /// Last user-facing outcome. Never contains any part of a key.
    private(set) var status: Status = .idle

    enum Status: Equatable {
        case idle
        case saved
        case forgotten
        case invalid(String)
    }

    init() {
        hasStoredKey = KeychainStore.hasValue()
    }

    /// True when the current draft would pass validation.
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

    /// Returns a human-readable problem if the input is unusable, or nil if it looks like a real key.
    /// Rejects empty/whitespace-only input and obvious un-filled placeholders.
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
}

// MARK: - View

struct KeyEntryView: View {
    @State private var store = KeyEntryStore()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                storedIndicator
            }

            Section {
                SecureField("Paste your key", text: $store.draft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit { store.save() }

                Button("Save key") {
                    fieldFocused = false
                    store.save()
                }
                .disabled(!store.canSave)
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Your key is stored only in this device's Keychain and is used directly to connect. It never leaves your device and is never shown again here.")
            }

            if store.hasStoredKey {
                Section {
                    Button("Forget key", role: .destructive) {
                        fieldFocused = false
                        store.forget()
                    }
                }
            }

            if let message = statusMessage {
                Section {
                    Label(message.text, systemImage: message.symbol)
                        .foregroundStyle(message.tint)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("API Key")
    }

    // MARK: Pieces

    @ViewBuilder
    private var storedIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: store.hasStoredKey ? "lock.fill" : "lock.open")
                .font(.title3)
                .foregroundStyle(store.hasStoredKey ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.hasStoredKey ? "Key stored" : "No key stored")
                    .font(.headline)
                Text(store.hasStoredKey ? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  (hidden, on this device)"
                                        : "Paste your OpenAI API key to connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var statusMessage: (text: String, symbol: String, tint: Color)? {
        switch store.status {
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
}

#Preview {
    NavigationStack {
        KeyEntryView()
    }
}
