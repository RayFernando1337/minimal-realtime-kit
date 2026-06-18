//  ConversationScreen.swift
//  T1.3 — the minimal voice screen: connect/stop, mute, live captions, key entry.
//
//  The screen is purely a CONTROL surface: it calls model.start()/stop()/setMuted() and
//  reads the model's @Observable state. It never owns audio or the session (SPEC N4), it
//  never routes the audio level through @State (SPEC N6 — that path is the model's
//  `currentLevel()`), and it handles only the six v1 events the model surfaces. BYO-key:
//  a settings button presents `KeyEntryView` in a sheet; when no key is stored the connect
//  control becomes a prominent "Add API Key" affordance, and a missing-key start() raises
//  the key sheet. `hasKey` is refreshed when the sheet dismisses.

import SwiftUI

struct ConversationScreen: View {
    /// The single owned model lives here at the screen root (created once via @State).
    @State private var model = ConversationModel()
    @State private var showingKeySheet = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 24) {
                header
                ScrollView {
                    captions
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollIndicators(.never)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.needsKey) { _, needsKey in
            if needsKey { showingKeySheet = true }
        }
        .onAppear { model.refreshHasKey() }
        .sheet(isPresented: $showingKeySheet, onDismiss: { model.refreshHasKey() }) {
            keySheet
        }
    }

    // MARK: - Background (dark, calm gradient consistent with the placeholder)

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.10),
                Color(red: 0.10, green: 0.11, blue: 0.17)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Header: title + live state label + the key/settings button

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("minimal realtime")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: statusLabel)
            }
            Spacer(minLength: 12)
            Button {
                showingKeySheet = true
            } label: {
                Image(systemName: model.hasKey ? "key.fill" : "key")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.hasKey ? Color.green.opacity(0.9) : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("API key settings")
        }
    }

    // MARK: - Captions: live "You" + "Agent" transcripts (plus any status hint)

    private var captions: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let hint = model.hint {
                hintBanner(hint)
            }
            if model.userText.isEmpty && model.pebblesText.isEmpty {
                emptyCaption
            } else {
                captionBlock(role: "You", text: model.userText, accent: .cyan)
                captionBlock(role: "Agent", text: model.pebblesText, accent: .purple)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: model.userText)
        .animation(.easeInOut(duration: 0.2), value: model.pebblesText)
    }

    @ViewBuilder
    private func captionBlock(role: String, text: String, accent: Color) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(role.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.6)
                    .foregroundStyle(accent.opacity(0.75))
                Text(text)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyCaption: some View {
        Text(emptyCaptionText)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyCaptionText: String {
        if model.isActive { return "Listening\u{2026} say hello." }
        return model.hasKey ? "Tap Connect and start talking." : "Add your OpenAI API key, then connect."
    }

    private func hintBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.25))
        )
    }

    // MARK: - Controls: the big connect/stop control + the mute toggle

    private var controls: some View {
        VStack(spacing: 16) {
            muteToggle
            connectControl
        }
    }

    private var connectControl: some View {
        Button(action: primaryAction) {
            HStack(spacing: 12) {
                controlIcon
                Text(controlLabel)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(controlFill, in: Capsule())
            .foregroundStyle(.white)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: model.state)
        .animation(.easeInOut(duration: 0.25), value: model.hasKey)
    }

    @ViewBuilder
    private var controlIcon: some View {
        switch model.state {
        case .connecting:
            ProgressView().tint(.white)
        case .dormant:
            Image(systemName: model.hasKey ? "mic.fill" : "key.fill")
        default:
            Image(systemName: "stop.fill")
        }
    }

    private var muteToggle: some View {
        Toggle(isOn: muteBinding) {
            Label(model.isMuted ? "Muted" : "Mute",
                  systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(model.isActive ? 0.9 : 0.35))
        }
        .toggleStyle(.switch)
        .tint(.purple)
        .disabled(!model.isActive)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { model.isMuted },
            set: { model.setMuted($0) }
        )
    }

    // MARK: - Key entry sheet (NavigationStack + a Done button; KeyEntryView owns the rest)

    private var keySheet: some View {
        NavigationStack {
            KeyEntryView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingKeySheet = false }
                    }
                }
        }
    }

    // MARK: - Actions

    private func primaryAction() {
        // With no key, the prominent path is straight to key entry (no failed round-trip).
        if !model.isActive && !model.hasKey {
            showingKeySheet = true
        } else {
            model.toggle()
        }
    }

    // MARK: - State → presentation

    /// The big control's label, reflecting the live state (exhaustive over PebblesState).
    private var controlLabel: String {
        switch model.state {
        case .dormant:    return model.hasKey ? "Connect" : "Add API Key"
        case .connecting: return "Connecting\u{2026}"
        case .idle:       return "Stop"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking"
        case .searching:  return "Searching\u{2026}"
        case .speaking:   return "Speaking"
        }
    }

    /// The header's smaller state caption.
    private var statusLabel: String {
        switch model.state {
        case .dormant:    return model.hasKey ? "Ready when you are" : "No API key yet"
        case .connecting: return "Connecting\u{2026}"
        case .idle:       return "Connected"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking\u{2026}"
        case .searching:  return "Searching\u{2026}"
        case .speaking:   return "Speaking\u{2026}"
        }
    }

    private var controlFill: Color {
        switch model.state {
        case .dormant:            return model.hasKey ? Color.accentColor.opacity(0.9) : Color.orange.opacity(0.9)
        case .connecting:         return Color.gray.opacity(0.55)
        case .idle:               return Color.blue.opacity(0.8)
        case .listening:          return Color.cyan.opacity(0.85)
        case .thinking, .searching: return Color.indigo.opacity(0.85)
        case .speaking:           return Color.purple.opacity(0.85)
        }
    }
}

#Preview {
    ConversationScreen()
}
