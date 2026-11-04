import Foundation

struct ToneConfig: Codable {
    var tone: String
    var alt: String
}

/// Everything user-configurable lives in ~/Library/Application Support/Yaptype/config.json.
struct Config: Codable {
    /// "v2" = Parakeet English-only (best English accuracy), "v3" = 25 European languages.
    var asrVersion = "v2"
    /// Input device: "" = system default, "builtin" = the Mac's own mic (silent while the lid is closed), or a device UID.
    var microphone = ""
    /// macOS virtual key code. 41 = ';'. Hotkey is Cmd + this key; Cmd+Shift + key uses the alt tone.
    var hotkeyKeyCode: UInt16 = 41
    /// Seconds. A press shorter than this switches to toggle mode (tap to start, tap to stop).
    var tapThreshold = 0.5
    var defaultTones = ToneConfig(tone: "professional", alt: "casual")
    /// Bundle identifier -> tones. Unlisted apps use defaultTones, which is professional for every app.
    var appTones: [String: ToneConfig] = [:]
    /// Bumped when the shipped tone defaults change. Configs written before version 2 are migrated once so existing
    /// installs stop lowercasing every dictation and stop skipping polish in editors.
    var tonePresetVersion = 2
    /// Tone name -> extra instruction for the polish model. An empty string means verbatim: skip the model entirely.
    var tones: [String: String] = [
        "supercasual": "Tone: super casual text to a close friend. Everything lowercase, including i, but names keep their capitals. Barely any punctuation: no commas at all, a full stop only between sentences when the message has several and never at the very end, question marks and apostrophes kept, no exclamation marks. Words just flow. Laughter and reactions (haha, lol, oh, wow) stay. Fillers like um and uh are removed.\nExample: \"Um, so, tomorrow is fine. See you then.\" -> \"so tomorrow is fine see you then\"\nExample: \"Haha. No, I really don't want to do it, but can you do it?\" -> \"haha no i really don't want to do it but can you do it?\"\nExample: \"Sure, see you at 5. Bring the charger.\" -> \"sure see you at 5. bring the charger\"\nExample: \"Hey Jordan, thanks a lot for reaching out! Haha, I appreciate the kind thoughts. I also locked in the place a few weeks before. Hope you can find someone to fill the spot soon.\" -> \"hey Jordan thanks a lot for reaching out haha i appreciate the kind thoughts. i also locked in the place a few weeks before hope you can find someone to fill the spot soon\"\nQuotation marks around quoted or mentioned words and titles still apply.",
        "casual": "Tone: casual message to a friend or a colleague you are on first-name terms with. Lowercase i and lowercase sentence starts, but names keep their capitals. Normal punctuation: commas between clauses and a full stop at the end of every sentence including the last one, question marks kept, no exclamation marks or semicolons. Contractions and everyday wording stay as spoken, nothing gets formalised. Laughter and reactions (haha, lol, oh, wow) stay. Fillers like um and uh are removed.\nExample: \"Um, so, tomorrow is fine. See you then.\" -> \"so tomorrow is fine. see you then.\"\nExample: \"Haha. No, I really don't want to do it, but can you do it?\" -> \"haha no, i really don't want to do it, but can you do it?\"\nExample: \"Hey Jordan, thanks a lot for reaching out! Haha, I appreciate the kind thoughts. I also locked in the place a few weeks before.\" -> \"hey Jordan, thanks a lot for reaching out haha, i appreciate the kind thoughts. i also locked in the place a few weeks before.\"",
        "professional": "Tone: message to a colleague or client. Normal capitalization and punctuation, complete sentences, no slang. Keep the speaker's own words and phrasing; fix grammar and remove fillers, but do not reword, formalize or restructure what they said.",
        "verbatim": "",
    ]
    /// Names and jargon, one per line: "Term" or "Term: sound-alike, sound-alike". Sound-alikes are replaced by
    /// rules, the term is boosted in speech recognition, and the polish model sees the list.
    var dictionary: [String] = ["Yaptype: yap type, yap-type, yap tight", "VS Code: vs code, vscode, pp code", "no wait: no wake, no weight, know wait"]
    /// Phrases learned from the speaker's corrections that turned out to mean "scratch that" (e.g. "i know" when
    /// the speech model misheard "no wait"). Fed to the polish model and used for routing.
    var learnedSignals: [String] = []
    /// Free-text background about the speaker that the polish model always sees (names, projects, spelling conventions).
    var memory = ""
    /// Save each dictation's audio to clips/ so `Yaptype --eval` can replay it against corrections.
    var keepClips = true
    /// Show the floating pill (waveform / transcribing) while dictating.
    var overlay = true
    /// Soft sounds on start and stop.
    var sounds = true
    /// Read the focused text field and window title (Accessibility) so the model knows what you're replying to.
    var fieldContext = true
    /// Type the live transcript into the field while talking; it is replaced by the polished text on release.
    var liveText = true
    /// Boost names from Contacts and today's calendar in speech recognition (asks for permission once).
    var useContacts = false
    /// Open the main window when the app starts (off keeps it to the Dock and menu bar, e.g. at login).
    var windowAtLaunch = true
    /// Apps where live text is not typed while talking (only the final paste): terminals redraw on every
    /// keystroke, which made removing the live text take longer than the paste.
    var liveTextExcluded: [String] = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                                      "io.alacritty", "com.mitchellh.ghostty", "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode"]
    /// OpenRouter key. Stored in plaintext in config.json on this Mac.
    var openRouterAPIKey = ""
    /// Primary polishing model, then the fallback used on rate limits or model errors.
    var openRouterModel = "nvidia/nemotron-3-ultra-550b-a55b:free"
    var openRouterFallbackModel = "google/gemma-4-26b-a4b-it:free"

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Yaptype", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("config.json")

    func tones(for bundleID: String?) -> ToneConfig {
        guard let bundleID, let t = appTones[bundleID] else { return defaultTones }
        return t
    }

    /// Loads config.json, writing the defaults first if it doesn't exist yet.
    static func load() throws -> Config {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Config().save()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.fileURL)
    }

    // Missing keys fall back to defaults so hand-edited configs stay forgiving.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        asrVersion = try c.decodeIfPresent(String.self, forKey: .asrVersion) ?? d.asrVersion
        microphone = try c.decodeIfPresent(String.self, forKey: .microphone) ?? d.microphone
        hotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? d.hotkeyKeyCode
        tapThreshold = try c.decodeIfPresent(Double.self, forKey: .tapThreshold) ?? d.tapThreshold
        let savedTonePreset = try c.decodeIfPresent(Int.self, forKey: .tonePresetVersion) ?? 1
        tonePresetVersion = max(savedTonePreset, 2)
        defaultTones = try c.decodeIfPresent(ToneConfig.self, forKey: .defaultTones) ?? d.defaultTones
        appTones = try c.decodeIfPresent([String: ToneConfig].self, forKey: .appTones) ?? d.appTones
        if savedTonePreset < 2 {
            // The old preset defaulted to supercasual and used verbatim in editors, which produced all-lowercase
            // or unpolished text depending on the app. Move existing installs to one consistent professional style.
            defaultTones = d.defaultTones
            appTones = d.appTones
        }
        tones = try c.decodeIfPresent([String: String].self, forKey: .tones) ?? d.tones
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? d.memory
        learnedSignals = try c.decodeIfPresent([String].self, forKey: .learnedSignals) ?? d.learnedSignals
        keepClips = try c.decodeIfPresent(Bool.self, forKey: .keepClips) ?? d.keepClips
        overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? d.overlay
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        fieldContext = try c.decodeIfPresent(Bool.self, forKey: .fieldContext) ?? d.fieldContext
        liveText = try c.decodeIfPresent(Bool.self, forKey: .liveText) ?? d.liveText
        useContacts = try c.decodeIfPresent(Bool.self, forKey: .useContacts) ?? d.useContacts
        windowAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .windowAtLaunch) ?? d.windowAtLaunch
        liveTextExcluded = try c.decodeIfPresent([String].self, forKey: .liveTextExcluded) ?? d.liveTextExcluded
        openRouterAPIKey = try c.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? d.openRouterAPIKey
        openRouterModel = try c.decodeIfPresent(String.self, forKey: .openRouterModel) ?? d.openRouterModel
        openRouterFallbackModel = try c.decodeIfPresent(String.self, forKey: .openRouterFallbackModel) ?? d.openRouterFallbackModel
    }
}
