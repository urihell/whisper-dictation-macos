/// Decisions for "GPU first, Neural Engine in the background". Pure (no
/// WhisperKit) so it's unit-tested.
///
/// Why: the first Neural Engine load of a model makes macOS compile it for the
/// ANE — minutes for large models — and that cache is invalidated whenever the
/// app binary changes (every update). Blocking dictation on it is what made
/// startup take 3+ minutes after updating. So a Neural-Engine model always
/// loads on the GPU first (seconds), serves dictation, and swaps to the ANE
/// copy once it's built — between dictations, never mid-session.
enum NeuralEngineUpgradePlan {
    enum Action: Equatable {
        /// Load a fresh copy on the requested backend (the old one serves meanwhile).
        case reload
        /// Keep the running GPU copy; build the ANE copy behind it.
        case startUpgrade
        /// Already on GPU as requested — just drop any pending ANE build.
        case cancelUpgrade
        /// Already running as requested.
        case none
    }

    /// What changing the ACTIVE model's compute backend should do.
    static func onBackendChange(wantsNeuralEngine: Bool, runningOnNeuralEngine: Bool) -> Action {
        switch (wantsNeuralEngine, runningOnNeuralEngine) {
        case (true, false): return .startUpgrade
        case (false, false): return .cancelUpgrade
        case (false, true): return .reload   // GPU loads in seconds
        case (true, true): return .none
        }
    }

    /// Whether a finished ANE copy may replace the running GPU copy now. Only
    /// for the model that's still active, and only between sessions — swapping
    /// mid-session would split the session's audio across two processors.
    static func canAdopt(upgradeModel: String, activeModel: String?, sessionRunning: Bool) -> Bool {
        upgradeModel == activeModel && !sessionRunning
    }
}
