import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import WhisperKit

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var transcriber = DictationController.shared.transcriber
    @State private var models: [String] = []
    @State private var audioDevices: [AudioDevice] = []
    @State private var showDeleteError = false
    @State private var deleteError: String?
    @State private var newTerm = ""
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView {
                general
                    .tabItem { Label("General", systemImage: "gearshape") }
                model
                    .tabItem { Label("Model", systemImage: "brain") }
                audio
                    .tabItem { Label("Audio", systemImage: "mic") }
                shortcut
                    .tabItem { Label("Shortcut", systemImage: "keyboard") }
                dictionary
                    .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            }
            .formStyle(.grouped)
            .tint(.brand)
        }
        .frame(width: 480)
        // This is a menu-bar-only (LSUIElement) app, so it isn't active by
        // default. Without activating, the Settings window can't become key and
        // the shortcut recorder never receives keystrokes.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whisper Dictation").font(.headline)
                Text("Version \(Self.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    /// "m:ss" elapsed between two dates, for the optimize timer.
    private static func elapsed(_ from: Date, to now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(from)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var general: some View {
        Form {
            Picker("Trigger mode", selection: $settings.triggerMode) {
                ForEach(TriggerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Type text directly (don't use the clipboard)", isOn: $settings.directTyping)
                Text("Most private: dictated text is typed straight into the app and never touches the clipboard, so no clipboard manager can record it. Turn off only if a particular app mishandles the typed text — then it falls back to clipboard paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settings.directTyping {
                Toggle("Restore clipboard after inserting", isOn: $settings.restoreClipboard)
            }

            Toggle("Press Return after inserting (submit)", isOn: $settings.pressReturnAfterInsert)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Voice formatting commands", isOn: $settings.voiceCommandsEnabled)
                Text("Say “new line”, “new paragraph”, “comma”, “period”, “question mark”, “colon”, etc. to insert formatting instead of typing the words. Like system dictation, punctuation words are always interpreted (e.g. “period” → “.”), so turn this off if you don’t want that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Auto-capitalize sentences", isOn: $settings.autoCapitalize)
                Text("Capitalizes the first letter of each sentence and line, plus the standalone “i” in English. Fast and on-device — no model needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Play a sound when dictation starts and stops", isOn: $settings.soundCuesEnabled)
                Text("A subtle cue so you know it’s listening (and when it stops) without looking at the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.soundCuesEnabled {
                    soundPicker("Start sound", selection: $settings.startSound)
                    soundPicker("Stop sound", selection: $settings.stopSound)
                }
            }

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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(loadStatus(for: loading))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { transcriber.cancelModelLoad() }
                            .controlSize(.small)
                    }
                    if let progress = transcriber.loadProgress {
                        // Download phase: real, determinate progress.
                        ProgressView(value: progress)
                    } else if let since = transcriber.optimizingSince {
                        // Optimize (Core ML/ANE compile) phase: no percentage is
                        // available, so show an indeterminate bar plus a live
                        // elapsed timer so it's clearly still working.
                        ProgressView().progressViewStyle(.linear)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Elapsed \(Self.elapsed(since, to: context.date))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        // Preparing (e.g. tokenizer/setup before progress is known).
                        ProgressView().progressViewStyle(.linear)
                    }
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
                        computePicker(for: name)
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
                Text("Compute is set per model. GPU starts in seconds and is the recommended default. The Neural Engine is more power-efficient and can be faster on large models; the first time a model loads on it, macOS runs a one-time optimization (the “optimizing” wait), then caches it so later launches are fast. Changing the active model's backend reloads it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var audio: some View {
        Form {
            Picker("Input device", selection: $settings.audioInputDeviceID) {
                Text("System Default").tag(UInt32(0))
                ForEach(audioDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            Text("Choose which microphone captures your voice. “System Default” follows whatever macOS is set to. A change takes effect on your next dictation.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh devices") { reloadAudioDevices() }
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Voice Isolation (suppress background noise)", isOn: $settings.voiceIsolationEnabled)
                Text("Runs your mic through Apple’s on-device voice processing to cancel echo and strip non-voice noise — fans, hum, music, keyboard — before transcription. It also attenuates distant background voices but can’t fully remove nearby chatter (that needs knowing which voice is yours). Uses the system default microphone (the input device above may be ignored while on). Takes effect on your next dictation.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .onAppear(perform: reloadAudioDevices)
    }

    private func reloadAudioDevices() {
        audioDevices = AudioProcessor.getAudioDevices()
        // If the saved device is gone (e.g. unplugged), fall back to the default.
        if settings.audioInputDeviceID != 0,
           !audioDevices.contains(where: { $0.id == settings.audioInputDeviceID }) {
            settings.audioInputDeviceID = 0
        }
    }

    /// Per-model GPU/Neural-Engine selector. Stores the choice for that model and,
    /// if it's the active one, reloads it so the new backend takes effect.
    private func computePicker(for name: String) -> some View {
        Picker("", selection: Binding(
            get: { settings.computeBackend(for: name) },
            set: { backend in
                guard backend != settings.computeBackend(for: name) else { return }
                settings.setComputeBackend(backend, for: name)
                if name == transcriber.loadedModel {
                    transcriber.reloadActiveModel()
                }
            }
        )) {
            Text("GPU").tag(ComputeBackend.gpu)
            Text("Neural Engine").tag(ComputeBackend.neuralEngine)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func loadStatus(for model: String) -> String {
        let name = DictationController.friendlyModelName(model)
        if let p = transcriber.loadProgress {
            return "Downloading \(name)… \(Int((p * 100).rounded()))%"
        }
        return "Optimizing \(name) for your Mac (first run) — current model stays active until it’s ready."
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

            Toggle("Require double-tap to start", isOn: $settings.doubleTapEnabled)

            if settings.doubleTapEnabled {
                Toggle("Submit also presses Return (send)", isOn: $settings.submitSendsReturn)
                Text("Double-tap to start dictation; a single tap — or the Return key — submits (stops and inserts). When the option above is on, submitting also presses Return to send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Single press works: in toggle mode press once to start and again to stop; in push-to-talk hold the trigger while you speak.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    private var dictionary: some View {
        Form {
            Section("Vocabulary") {
                HStack {
                    TextField("Add a word, name, or acronym…", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.vocabularyTerms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button(role: .destructive) {
                            settings.vocabularyTerms.removeAll { $0 == term }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                Toggle("Bias recognition using these terms", isOn: $settings.vocabularyBiasing)
                Text("When on, seeds the recognizer so these terms are spelled correctly (strong nudge, not a guarantee). ⚠️ Slows live transcription — it disables a speed optimization. Off by default; Replacements below work regardless and cost nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Replacements") {
                HStack {
                    TextField("Heard…", text: $newWrong)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replace with…", text: $newRight)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.replacements.sorted { $0.key.lowercased() < $1.key.lowercased() }, id: \.key) { pair in
                    HStack {
                        Text(pair.key)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(pair.value)
                        Spacer()
                        Button(role: .destructive) {
                            settings.replacements[pair.key] = nil
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Applied after transcription, case-insensitive (e.g. “sales force” → “Salesforce”).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    /// A sound dropdown with a preview button; picking a new sound auditions it.
    private func soundPicker(_ label: String, selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Picker(label, selection: selection) {
                Text("None").tag(SoundFeedback.none)
                Divider()
                ForEach(SoundFeedback.available, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: selection.wrappedValue) { SoundFeedback.preview(selection.wrappedValue) }
            Button {
                SoundFeedback.preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection.wrappedValue == SoundFeedback.none)
            .help("Preview")
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !settings.vocabularyTerms.contains(term) else { return }
        settings.vocabularyTerms.append(term)
        newTerm = ""
    }

    private func addReplacement() {
        let wrong = newWrong.trimmingCharacters(in: .whitespaces)
        let right = newRight.trimmingCharacters(in: .whitespaces)
        guard !wrong.isEmpty else { return }
        settings.replacements[wrong] = right
        newWrong = ""
        newRight = ""
    }
}
