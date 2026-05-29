import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            model
                .tabItem { Label("Model", systemImage: "brain") }
            shortcut
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
        }
        .frame(width: 480)
        .padding()
        // This is a menu-bar-only (LSUIElement) app, so it isn't active by
        // default. Without activating, the Settings window can't become key and
        // the shortcut recorder never receives keystrokes.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private var general: some View {
        Form {
            Picker("Trigger mode", selection: $settings.triggerMode) {
                ForEach(TriggerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Toggle("Restore clipboard after inserting", isOn: $settings.restoreClipboard)

            Toggle("Press Return after inserting (submit)", isOn: $settings.pressReturnAfterInsert)

            LaunchAtLogin.Toggle("Launch at login")

            Picker("Language", selection: $settings.language) {
                Text("Auto-detect").tag("auto")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("Hebrew").tag("he")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Portuguese").tag("pt")
                Text("Mandarin").tag("zh")
            }
        }
        .padding()
    }

    private var model: some View {
        Form {
            Picker("Whisper model", selection: $settings.modelName) {
                Text("Tiny — fastest, lowest accuracy").tag("openai_whisper-tiny")
                Text("Base — fast, decent").tag("openai_whisper-base")
                Text("Small — balanced").tag("openai_whisper-small")
                Text("Medium — accurate").tag("openai_whisper-medium")
                Text("Large v3 — best multilingual").tag("openai_whisper-large-v3")
            }

            Text("Models download on first use and are cached on-device. Larger models are more accurate but slower and use more memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var shortcut: some View {
        Form {
            Picker("Trigger style", selection: $settings.useSingleKey) {
                Text("Key combination").tag(false)
                Text("Single key").tag(true)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: settings.useSingleKey) { HotkeyManager.shared.reconfigure() }

            if settings.useSingleKey {
                LabeledContent("Dictation key:") {
                    SingleKeyRecorder(settings: settings)
                }
                Text("Press any single key. ⚠️ While set, that key is captured system-wide and won't type its character anywhere — pick a key you don't otherwise need (a function key is safest).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                KeyboardShortcuts.Recorder("Dictation hotkey:", name: .toggleDictation)
            }

            Text("In push-to-talk mode, hold the trigger while you speak. In toggle mode, press once to start and again to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}
