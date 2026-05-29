import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var transcriber = DictationController.shared.transcriber
    @State private var models: [String] = []
    @State private var showDeleteError = false
    @State private var deleteError: String?

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

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Clean up speech (remove self-corrections & filler)", isOn: $settings.cleanupEnabled)
                    .disabled(!SpeechCleaner.isAvailable)
                if let reason = SpeechCleaner.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Uses Apple's on-device model — fully private, but adds several seconds after you stop (model is slow per call). Best left off unless you need correction cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                Text("Large v3 Turbo — best for other languages, fast").tag("openai_whisper-large-v3-v20240930_turbo_632MB")
                Text("Large v3 — most accurate, slowest").tag("openai_whisper-large-v3")
            }
            .onChange(of: settings.modelName) {
                // Load the new model in the background; keep using the current
                // one until it's ready (large models take minutes to compile).
                DictationController.shared.transcriber.requestModel(settings.modelName)
            }

            if let loading = transcriber.loadingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(DictationController.friendlyModelName(loading)) in the background — current model stays active until it's ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { transcriber.cancelModelLoad() }
                        .controlSize(.small)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Models download on first use and are cached on-device. Larger models are more accurate but slower and use more memory. The first load of a large model can take a few minutes to compile (one-time); you can keep dictating with the current model meanwhile. For non-English (e.g. Hebrew), use Large v3 Turbo or larger — and set a specific Language below rather than Auto-detect.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Section("Downloaded models") {
                if models.isEmpty {
                    Text("None downloaded yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(models, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(DictationController.friendlyModelName(name))
                        if name == transcriber.loadedModel {
                            Text("Active").font(.caption2).foregroundStyle(.green)
                        }
                        Spacer()
                        Text(ModelManager.sizeString(of: name))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            delete(name)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(name == transcriber.loadedModel
                                  || name == transcriber.loadingModel
                                  || models.count <= 1)
                        .help(deleteHelp(for: name))
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reloadModels)
        .onChange(of: transcriber.loadedModel) { reloadModels() }
        .onChange(of: transcriber.loadingModel) { reloadModels() }
        .alert("Couldn't delete model", isPresented: $showDeleteError, presenting: deleteError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private func reloadModels() {
        models = ModelManager.downloadedModels()
    }

    private func delete(_ name: String) {
        do {
            try transcriber.deleteModel(name)
            reloadModels()
        } catch {
            deleteError = error.localizedDescription
            showDeleteError = true
        }
    }

    private func deleteHelp(for name: String) -> String {
        if name == transcriber.loadedModel { return "Active model — switch away to delete." }
        if name == transcriber.loadingModel { return "Loading — cancel first." }
        if models.count <= 1 { return "Keep at least one model." }
        return "Delete this model from disk."
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

            Toggle("Double-tap to start hands-free dictation", isOn: $settings.doubleTapEnabled)

            Text("In push-to-talk mode, hold the trigger while you speak. In toggle mode, press once to start and again to stop. When enabled, double-tap (either mode) starts hands-free dictation that keeps going until you press once to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}
