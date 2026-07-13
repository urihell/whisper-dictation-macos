import SwiftUI
import AppKit
import KeyboardShortcuts

/// First-launch introduction. This is a menu-bar (LSUIElement) app with no Dock
/// icon and no main window, so a brand-new user double-clicks it and sees…
/// nothing. This window explains where the app lives and how to start dictating
/// so it doesn't feel broken. Dismissable, and disableable for next launch.
struct WelcomeView: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Called when the user dismisses the window.
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Welcome to Whisper Dictation")
                    .font(.title2.weight(.semibold))
                Text("Private, on-device voice typing — anywhere you can type.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background(Color.brand.opacity(0.10))

            VStack(alignment: .leading, spacing: 18) {
                step(
                    icon: "menubar.arrow.up.rectangle",
                    title: "It lives in your menu bar",
                    detail: "Look at the top-right of your screen for the Whisper Dictation icon. There’s no Dock icon and no main window — that’s normal, not a bug."
                )
                step(
                    icon: "keyboard",
                    title: "Start dictating",
                    detail: triggerDetail
                )
                step(
                    icon: "checkmark.shield",
                    title: "Allow the permissions",
                    detail: "The first time, macOS asks for Microphone and Accessibility access. Allow both — without them the app can’t hear you or type for you."
                )
                step(
                    icon: "arrow.down.circle",
                    title: "The first dictation downloads a model",
                    detail: "One time only, and it needs internet — the HUD shows the progress (“Downloading… / Optimizing…”), so a slow first run is normal, not stuck. After that, everything runs offline and starts instantly."
                )
                step(
                    icon: "lock.fill",
                    title: "100% on your Mac",
                    detail: "Speech is transcribed on-device and typed straight in. Your audio and text never leave your computer."
                )
                step(
                    icon: "slider.horizontal.3",
                    title: "Make it yours",
                    detail: "Open Settings (⌘, from the menu bar icon) for languages, engines, per-app behavior, custom vocabulary, and spoken punctuation like “comma” and “new line”."
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider()

            HStack {
                Toggle("Show this on launch", isOn: $settings.showWelcomeOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Button("Get Started") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Start dictating" copy, tailored to the configured trigger so it always
    /// matches what's actually wired up.
    private var triggerDetail: String {
        let action = settings.doubleTapEnabled
            ? "double-tap \(triggerName)"
            : "press \(triggerName)"
        return "From any app, \(action), speak, then \(stopHint). Your words type in right at the cursor. Press Escape anytime to cancel and discard."
    }

    private var stopHint: String {
        if settings.doubleTapEnabled {
            return "tap it once (or press Return) to finish"
        }
        switch settings.triggerMode {
        case .toggle: return "press it again to stop"
        case .pushToTalk: return "release it to stop"
        }
    }

    /// Friendly name of the current trigger key/shortcut.
    private var triggerName: String {
        if settings.useSingleKey, !settings.singleKeyLabel.isEmpty {
            return "the \(settings.singleKeyLabel) key"
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return shortcut.description
        }
        return "your dictation shortcut"
    }
}
