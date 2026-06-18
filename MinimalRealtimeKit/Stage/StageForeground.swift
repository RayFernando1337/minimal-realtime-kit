//  StageForeground.swift
//  T3.0 — the front of the sandwich: live captions + the connect/stop/mute controls + the BYO-key
//  sheet + the dormant wake-catcher. This is where the Tier-1 `ConversationScreen`'s control surface
//  now lives (the screen + RootView are deleted; the single `ConversationModel` lives in App.swift).
//
//  It is purely a CONTROL surface: it calls convo.start()/stop()/setMuted()/refreshHasKey() and READS
//  the model's @Observable state (N4 — it never owns audio/session). It never routes the audio level
//  through @State (N6 — that path is the scene's per-frame `levelProvider`).
//
//  Layout: the character (the full-screen SKView behind this host) shows through a transparent
//  reserved band (the flexible spacer); captions tuck beneath it and the controls sit in the thumb
//  zone. The dormant wake-catcher is a full-screen clear layer at the BACK of the ZStack so the
//  controls win their own taps and every OTHER tap while dormant wakes the session.

import SwiftUI

struct StageForeground: View {
    @Environment(ConversationModel.self) private var convo
    @State private var showingKeySheet = false

    var body: some View {
        ZStack {
            // Dormant wake-catcher: full-screen, interactive ONLY while dormant, at the BACK of the
            // stack. SwiftUI routes touches the greedy host receives to this view internally; the
            // UIKit stage only intercepts AWAKE orb taps ahead of the host, so this never fights poke.
            if convo.state == .dormant {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { convo.start() }
                    .accessibilityElement()
                    .accessibilityLabel("Wake")
                    .accessibilityAddTraits(.isButton)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)                 // the character's reserved band (SKView draws behind it)
                captions
                if let hint = convo.hint { hintBanner(hint) }
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear { convo.refreshHasKey() }
        .onChange(of: convo.needsKey) { _, needsKey in
            if needsKey { showingKeySheet = true }
        }
        .sheet(isPresented: $showingKeySheet, onDismiss: { convo.refreshHasKey() }) {
            keySheet
        }
    }

    // MARK: - Top bar: title + live status + the key/settings button

    private var topBar: some View {
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
                Image(systemName: convo.hasKey ? "key.fill" : "key")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(convo.hasKey ? Color.green.opacity(0.9) : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("API key settings")
        }
    }

    // MARK: - Captions: the agent's words emphasized, the user's quieter (plus a soft status fallback)

    private var captions: some View {
        VStack(spacing: 10) {
            Caption(text: topText, emphasized: !convo.pebblesText.isEmpty)
            Caption(text: convo.userText, emphasized: false)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
    }

    /// The agent's live words when talking; otherwise a soft status so the user always knows what's
    /// happening. Dormant/speaking-with-no-text are intentionally blank.
    private var topText: String {
        if !convo.pebblesText.isEmpty { return convo.pebblesText }
        switch convo.state {
        case .connecting: return "Waking up\u{2026}"
        case .idle:       return "Listening for you"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking\u{2026}"
        case .searching:  return "Looking that up\u{2026}"
        case .dormant, .speaking: return ""
        }
    }

    // MARK: - Controls: the mute toggle + the big connect/stop control

    private var controls: some View {
        VStack(spacing: 14) {
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
            .frame(height: 60)
            .background(controlFill, in: Capsule())
            .foregroundStyle(.white)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: convo.state)
        .animation(.easeInOut(duration: 0.25), value: convo.hasKey)
    }

    @ViewBuilder
    private var controlIcon: some View {
        switch convo.state {
        case .connecting:
            ProgressView().tint(.white)
        case .dormant:
            Image(systemName: convo.hasKey ? "mic.fill" : "key.fill")
        default:
            Image(systemName: "stop.fill")
        }
    }

    private var muteToggle: some View {
        Toggle(isOn: muteBinding) {
            Label(convo.isMuted ? "Muted" : "Mute",
                  systemImage: convo.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(convo.isActive ? 0.9 : 0.35))
        }
        .toggleStyle(.switch)
        .tint(.purple)
        .disabled(!convo.isActive)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { convo.isMuted },
            set: { convo.setMuted($0) }
        )
    }

    // MARK: - Hint banner (status / error line; never any key material — N1)

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
        .padding(.bottom, 12)
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
        if !convo.isActive && !convo.hasKey {
            showingKeySheet = true
        } else {
            convo.toggle()
        }
    }

    // MARK: - State → presentation (exhaustive over PebblesState)

    /// The big control's label, reflecting the live state.
    private var controlLabel: String {
        switch convo.state {
        case .dormant:    return convo.hasKey ? "Connect" : "Add OpenAI API Key"
        case .connecting: return "Connecting\u{2026}"
        case .idle:       return "Stop"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking"
        case .searching:  return "Searching\u{2026}"
        case .speaking:   return "Speaking"
        }
    }

    /// The top bar's smaller state caption.
    private var statusLabel: String {
        switch convo.state {
        case .dormant:    return convo.hasKey ? "Ready when you are" : "No API key yet"
        case .connecting: return "Connecting\u{2026}"
        case .idle:       return "Connected"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking\u{2026}"
        case .searching:  return "Searching\u{2026}"
        case .speaking:   return "Speaking\u{2026}"
        }
    }

    private var controlFill: Color {
        switch convo.state {
        case .dormant:              return convo.hasKey ? Color.accentColor.opacity(0.9) : Color.orange.opacity(0.9)
        case .connecting:           return Color.gray.opacity(0.55)
        case .idle:                 return Color.blue.opacity(0.8)
        case .listening:            return Color.cyan.opacity(0.85)
        case .thinking, .searching: return Color.indigo.opacity(0.85)
        case .speaking:             return Color.purple.opacity(0.85)
        }
    }
}

#Preview {
    StageForeground()
        .environment(ConversationModel())
}
