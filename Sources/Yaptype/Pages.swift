import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var store: Store
    @State private var newTerm = ""
    @State private var adding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictionary", subtitle: "Names and jargon spelled exactly like this. Sound-alikes in the transcript get replaced.") {
                PrimaryButton(title: "Add new") { adding = true; focused = true }
            }
            if adding {
                HStack {
                    TextField("Term, or Term: sound-alike, sound-alike (e.g. Zentro: zentrow, zen tro)", text: $newTerm).field().focused($focused).onSubmit(add)
                    PrimaryButton(title: "Save", action: add)
                    SecondaryButton(title: "Cancel") { adding = false; newTerm = "" }
                }
                .padding(.bottom, 16)
            }
            if store.config.dictionary.isEmpty {
                Text("No terms yet.").foregroundStyle(Theme.secondary)
            } else {
                ScrollView {
                    CardList {
                        ForEach(Array(store.config.dictionary.enumerated()), id: \.element) { i, term in
                            if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            RowCard {
                                Text(term).font(.system(size: 15)).foregroundStyle(Theme.text)
                            } actions: {
                                IconButton(symbol: "trash", help: "Delete") {
                                    store.config.dictionary.removeAll { $0 == term }; store.save()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if !store.config.dictionary.contains(t) { store.config.dictionary.insert(t, at: 0); store.save() }
        newTerm = ""; adding = false
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var store: Store
    @State private var tab = "tones"
    @State private var selected: String?
    @State private var rename = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Style", subtitle: "How your dictation reads, and which style each app gets.") {
                if tab == "tones" { PrimaryButton(title: "Add tone", action: addTone) }
            }
            Tabs(items: [("tones", "Tones"), ("apps", "Apps")], selection: $tab)
            if tab == "tones" { tones } else { apps }
        }
        .onAppear { if selected == nil { selected = store.config.defaultTones.tone; rename = selected ?? "" } }
    }

    // Tones: card grid + editor for the selected one.
    private var tones: some View {
        let names = store.config.tones.keys.sorted()
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(names, id: \.self) { name in toneCard(name) }
                }
                if let name = selected, store.config.tones[name] != nil { editor(name) }
            }
            .padding(.bottom, 20)
        }
    }

    private func toneCard(_ name: String) -> some View {
        let on = selected == name
        let instruction = store.config.tones[name] ?? ""
        let d = store.config.defaultTones
        return Button { selected = name; rename = name } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name.capitalized).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    if d.tone == name { badge("Default") } else if d.alt == name { badge("Alt") }
                }
                Text(instruction.isEmpty ? "Verbatim — pasted exactly as transcribed." : instruction)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(height: 130, alignment: .topLeading)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accentSoft, in: Capsule())
    }

    private func editor(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Tone name", text: $rename).field().frame(width: 220).onSubmit { renameTone(name) }
                Spacer()
                SecondaryButton(title: "Set as default") { store.config.defaultTones.tone = name; store.save() }
                SecondaryButton(title: "Set as alt (⌘⇧;)") { store.config.defaultTones.alt = name; store.save() }
                SecondaryButton(title: "Delete", destructive: true) {
                    store.config.tones[name] = nil; store.save(); selected = store.config.defaultTones.tone
                }
            }
            Text("Instruction given to the polish model after the cleanup rules. Leave empty for verbatim.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            TextEditor(text: Binding(get: { store.config.tones[name] ?? "" },
                                     set: { store.config.tones[name] = $0; store.save() }))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 200)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    private func addTone() {
        var name = "new tone"; var n = 2
        while store.config.tones[name] != nil { name = "new tone \(n)"; n += 1 }
        store.config.tones[name] = "Tone: "
        store.save()
        selected = name; rename = name
    }

    private func renameTone(_ old: String) {
        let new = rename.trimmingCharacters(in: .whitespaces).lowercased()
        guard !new.isEmpty, new != old, store.config.tones[new] == nil else { return }
        store.config.tones[new] = store.config.tones.removeValue(forKey: old)
        if store.config.defaultTones.tone == old { store.config.defaultTones.tone = new }
        if store.config.defaultTones.alt == old { store.config.defaultTones.alt = new }
        for (k, v) in store.config.appTones {
            store.config.appTones[k] = ToneConfig(tone: v.tone == old ? new : v.tone, alt: v.alt == old ? new : v.alt)
        }
        store.save(); selected = new
    }

    // Apps: default pair + per-app rows.
    @State private var newBundle = ""
    private var apps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("⌘; uses the app's tone, ⌘⇧; its alternate. Apps not listed use the default.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                SectionLabel(text: "Default")
                CardList {
                    RowCard {
                        Text("All other apps").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                        tonePickers(Binding(get: { store.config.defaultTones }, set: { store.config.defaultTones = $0; store.save() }))
                    } actions: { EmptyView() }
                }
                SectionLabel(text: "Per app")
                CardList {
                    ForEach(Array(store.config.appTones.keys.sorted().enumerated()), id: \.element) { i, bundle in
                        if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        RowCard {
                            if let icon = appIcon(for: bundle) {
                                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appDisplayName(for: bundle)).font(.system(size: 15)).foregroundStyle(Theme.text)
                                Text(bundle).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                            Spacer()
                            tonePickers(Binding(get: { store.config.appTones[bundle] ?? store.config.defaultTones },
                                                set: { store.config.appTones[bundle] = $0; store.save() }))
                        } actions: {
                            IconButton(symbol: "trash", help: "Remove") { store.config.appTones[bundle] = nil; store.save() }
                        }
                    }
                }
                HStack {
                    Menu {
                        ForEach(runningApps(), id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) { newBundle = app.bundleIdentifier! }
                        }
                    } label: { Text("Running app…") }
                    .frame(width: 150)
                    TextField("or type a bundle identifier", text: $newBundle).field().onSubmit(addApp)
                    PrimaryButton(title: "Add", action: addApp)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func tonePickers(_ b: Binding<ToneConfig>) -> some View {
        let names = store.config.tones.keys.sorted()
        return HStack(spacing: 10) {
            Picker("", selection: Binding(get: { b.wrappedValue.tone }, set: { b.wrappedValue.tone = $0 })) {
                ForEach(names, id: \.self) { Text($0.capitalized).tag($0) }
            }.frame(width: 130)
            Text("alt").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Picker("", selection: Binding(get: { b.wrappedValue.alt }, set: { b.wrappedValue.alt = $0 })) {
                ForEach(names, id: \.self) { Text($0.capitalized).tag($0) }
            }.frame(width: 130)
        }
    }

    private func addApp() {
        let b = newBundle.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        store.config.appTones[b] = store.config.defaultTones; store.save(); newBundle = ""
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != "com.yaptype.app" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Memory", subtitle: "Background the polish model always knows about you. Used for context only, never inserted into your text.")
            TextEditor(text: store.bind(\.memory))
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            Text("Example: \"I'm Taylor, based in Melbourne. I run a small design studio called Acme Studio and I use Australian spelling.\"").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Models

struct ModelsPage: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Models", subtitle: "Parakeet runs on this Mac. Text polishing is the only step that uses the network.")
            SectionLabel(text: "Speech model")
            CardList {
                RowCard {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Parakeet TDT 0.6B").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("NVIDIA, on CoreML. Downloaded once (~600 MB). v2 is English-only and most accurate; v3 covers 25 European languages.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { store.config.asrVersion }, set: { store.setAsrVersion($0) })) {
                        Text("v2 English").tag("v2"); Text("v3 Multilingual").tag("v3")
                    }.frame(width: 160)
                } actions: { EmptyView() }
            }
            SectionLabel(text: "Text polishing")
            CardList {
                RowCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenRouter").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(store.polishReady
                             ? "Configured. Transcripts are sent for cleanup; microphone audio never leaves this Mac."
                             : "No API key yet. Dictation still works with the deterministic rules; add a key in Settings to enable polishing.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Text("Primary: \(store.config.openRouterModel)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tertiary)
                        Text("Fallback: \(store.config.openRouterFallbackModel)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(store.polishReady ? "Ready" : "Not configured")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.polishReady ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                } actions: { EmptyView() }
            }
        }.padding(.bottom, 24) }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Settings")
            SectionLabel(text: "Hotkey")
            CardList {
                settingRow("Dictate", "Hold to talk, quick tap to toggle, Esc cancels") { keycap("⌘ ;") }
                divider
                settingRow("Alternate tone", "Same, but uses the app's alt tone") { keycap("⌘ ⇧ ;") }
                divider
                settingRow("Tap threshold", "Presses shorter than this switch to toggle mode") {
                    HStack {
                        Slider(value: store.bind(\.tapThreshold), in: 0.2...1.0, step: 0.05).frame(width: 160).tint(Theme.accent)
                        Text("\(store.config.tapThreshold, specifier: "%.2f") s").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 48)
                    }
                }
            }
            SectionLabel(text: "App")
            CardList {
                settingRow("Open window at launch", "Off keeps it to the Dock and menu bar, handy with Launch at login") {
                    Toggle("", isOn: store.bind(\.windowAtLaunch)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Launch at login", "Keep Yaptype in the menu bar") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).tint(Theme.accent)
                        .onChange(of: launchAtLogin) { _, on in
                            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
                divider
                settingRow("Config folder", Config.directory.path) {
                    SecondaryButton(title: "Open") { NSWorkspace.shared.open(Config.directory) }
                }
            }
            SectionLabel(text: "Microphone")
            CardList {
                settingRow("Input device", "The built-in mic is silent while the lid is closed; AirPods are fine but narrowband") {
                    Picker("", selection: store.bind(\.microphone)) {
                        Text("System default").tag("")
                        Text("Built-in microphone").tag("builtin")
                        ForEach(AudioDevices.inputs().filter { !$0.isBuiltIn }) { d in Text(d.name).tag(d.uid) }
                    }
                    .labelsHidden().frame(width: 230)
                }
            }
            SectionLabel(text: "While dictating")
            CardList {
                settingRow("Floating pill", "Waveform at the bottom of the screen while listening") {
                    Toggle("", isOn: store.bind(\.overlay)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Sounds", "Soft cue on start and stop") {
                    Toggle("", isOn: store.bind(\.sounds)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Live text in the field", "Types what it hears as you talk, then swaps in the polished text") {
                    Toggle("", isOn: store.bind(\.liveText)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Read the field you're typing in", "Window title and existing text help with names and mid-sentence continuation") {
                    Toggle("", isOn: store.bind(\.fieldContext)).toggleStyle(.switch).tint(Theme.accent)
                }
            }
            SectionLabel(text: "Polishing")
            CardList {
                settingRow("OpenRouter API key", "Create one at openrouter.ai/keys. Stored in config.json on this Mac; audio is transcribed locally and never uploaded") {
                    SecureField(keyPlaceholder, text: store.bind(\.openRouterAPIKey)).field().frame(width: 300)
                }
                divider
                settingRow("Primary model", "Used first for every cleanup") {
                    TextField("", text: store.bind(\.openRouterModel)).field().frame(width: 340)
                }
                divider
                settingRow("Fallback model", "Tried when the primary is rate-limited, unavailable or rejects the request") {
                    TextField("", text: store.bind(\.openRouterFallbackModel)).field().frame(width: 340)
                }
            }
            SectionLabel(text: "Names")
            CardList {
                settingRow("Use Contacts and Calendar", "Names of people, companies and today's attendees are recognised better (asks for access once)") {
                    Toggle("", isOn: store.bind(\.useContacts)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Learned automatically", "Correcting a name with the pencil on Home adds it to the Dictionary with what was heard; names visible where you type are boosted per dictation") {
                    Text("\(store.config.dictionary.count) terms").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            SectionLabel(text: "Tuning")
            CardList {
                settingRow("Keep audio clips", "Saves each dictation's audio in the config folder, never leaves this Mac") {
                    Toggle("", isOn: store.bind(\.keepClips)).toggleStyle(.switch).tint(Theme.accent)
                }
                divider
                settingRow("Corrections", "\(store.correctionCount) saved · the pencil on a dictation teaches the polish model your style") {
                    SecondaryButton(title: "Copy eval command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/Applications/Yaptype.app/Contents/MacOS/Yaptype --eval", forType: .string)
                    }
                }
            }
        }
        .padding(.bottom, 24)
        }
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }
    private var keyPlaceholder: String { "sk-or-…" }

    private func keycap(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func settingRow<V: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> V) -> some View {
        RowCard {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        } actions: { EmptyView() }
    }
}
