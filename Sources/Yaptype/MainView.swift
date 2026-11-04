import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", dictionary = "Dictionary", style = "Style", memory = "Memory",
         models = "Models", insights = "Insights", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "mic"; case .dictionary: "character.book.closed"; case .style: "textformat"
        case .memory: "brain"; case .models: "cpu"; case .insights: "chart.bar"; case .settings: "gearshape"
        }
    }
    static let main: [Page] = [.home, .insights, .dictionary, .style, .memory, .models]
}

struct MainView: View {
    @ObservedObject var store: Store
    @State private var page: Page

    init(store: Store, initial: Page = .home) {
        self.store = store
        _page = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                content
                    .padding(36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .padding([.trailing, .bottom], 14)
            .padding(.top, 8)
        }
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 620)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home: HomePage(store: store)
        case .dictionary: DictionaryPage(store: store)
        case .style: StylePage(store: store)
        case .memory: MemoryPage(store: store)
        case .models: ModelsPage(store: store)
        case .insights: InsightsPage(store: store)
        case .settings: SettingsPage(store: store)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Yaptype").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Text("On-device").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.leading, 22).padding(.top, 44).padding(.bottom, 26)

            ForEach(Page.main) { navItem($0) }
            Spacer()
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 18).padding(.bottom, 8)
            navItem(.settings)
            Button { if let u = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(u) } } label: {
                navLabel("Help", icon: "questionmark.circle", selected: false)
            }
            .buttonStyle(.plain)
            statusFooter
        }
        .padding(.horizontal, 10).padding(.bottom, 16)
    }

    private func navItem(_ p: Page) -> some View {
        Button { page = p } label: { navLabel(p.rawValue, icon: p.icon, selected: page == p) }
            .buttonStyle(.plain)
    }

    private func navLabel(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 22)
            Text(title).font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(store.speechReady && store.polishReady ? Color.green : (store.speechReady ? Color.yellow : Color.gray)).frame(width: 7, height: 7)
            Text(store.status).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var store: Store
    @State private var query = ""

    private var filtered: [Dictation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.history : store.history.filter { $0.text.lowercased().contains(q) }
    }

    private var grouped: [(String, [Dictation])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"
        var out: [(String, [Dictation])] = []
        for d in filtered {
            let label = cal.isDateInToday(d.date) ? "Today" : cal.isDateInYesterday(d.date) ? "Yesterday" : f.string(from: d.date)
            if out.last?.0 == label { out[out.count - 1].1.append(d) } else { out.append((label, [d])) }
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Dictation", subtitle: "Hold ⌘; anywhere to talk. Audio and speech recognition stay on this Mac; only text is polished with OpenRouter.")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Search dictations", text: $query).textFieldStyle(.plain).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .padding(.bottom, 18)

                if filtered.isEmpty {
                    Text(store.history.isEmpty ? "No dictations yet. Hold ⌘; and say something." : "No matches.")
                        .foregroundStyle(Theme.secondary).padding(.top, 20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(grouped, id: \.0) { label, items in
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionLabel(text: label)
                                    CardList {
                                        ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                                            if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                            HistoryRow(store: store, d: d)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                statPanel
                enginePanel
            }
            .frame(width: 250)
            .padding(.top, 74)
        }
    }

    private var statPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigStat("\(store.stats.words.formatted())", "total words")
            bigStat("\(store.stats.wordsPerMinute)", "wpm")
            bigStat("\(store.stats.streak)", store.stats.streak == 1 ? "day streak" : "day streak")
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engines").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            engineLine("Parakeet \(store.config.asrVersion)", ok: store.speechReady)
            engineLine(store.polishReady ? "OpenRouter · \(shortModel(store.config.openRouterModel))" : "OpenRouter · no API key",
                       ok: store.polishReady)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }

    private func engineLine(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(name).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }

    private func shortModel(_ id: String) -> String {
        id.replacingOccurrences(of: ":free", with: "").split(separator: "/").last.map(String.init) ?? id
    }
}

struct HistoryRow: View {
    @ObservedObject var store: Store
    let d: Dictation
    @State private var copied = false
    @State private var editing = false
    @State private var draft = ""

    private var shown: String { d.correction ?? d.text }

    var body: some View {
        RowCard {
            Text(Self.time.string(from: d.date)).font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    Text("Heard: \(d.raw)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    TextEditor(text: $draft).font(.system(size: 15)).foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden).frame(minHeight: 56)
                        .padding(6).background(Theme.window, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    HStack(spacing: 8) {
                        PrimaryButton(title: "Save correction") { store.setCorrection(d, draft); editing = false }
                        SecondaryButton(title: "Cancel") { editing = false }
                    }
                    .padding(.top, 4)
                } else {
                    Text(shown).font(.system(size: 15)).foregroundStyle(Theme.text).textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let app = d.app { Text(appDisplayName(for: app)) }
                        if !d.tone.isEmpty { Text("·"); Text(d.tone) }
                        if d.seconds > 0 { Text("·"); Text("\(Int(d.seconds))s") }
                        if d.correction != nil { Text("·"); Text("corrected").foregroundStyle(Theme.accent) }
                        if d.hasClip { Text("·"); Image(systemName: "waveform") }
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        } actions: {
            if !editing {
                IconButton(symbol: "pencil", help: "Correct: save what this should have said") { draft = shown; editing = true }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                IconButton(symbol: "trash", help: "Delete") { store.delete(d) }
            }
        }
    }

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
}

// MARK: - Insights

struct InsightsPage: View {
    @ObservedObject var store: Store

    var body: some View {
        let s = store.stats
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Insights", subtitle: "All-time, counted locally since you installed Yaptype.")
            HStack(spacing: 16) {
                StatTile(value: "\(s.wordsPerMinute)", label: "Words per minute") {
                    Text("Speaking is ~3× faster than typing").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                StatTile(value: s.words.formatted(), label: "Total words dictated") {
                    Text("\(s.dictations) dictations").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                StatTile(value: "\(s.streak)", label: "Day streak") {
                    Text("\(s.activeDays.count) active days").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 16) {
                usagePanel("App usage", rows: s.perApp.map { (appDisplayName(for: $0.key), $0.value) })
                usagePanel("Tone usage", rows: s.perTone.map { ($0.key.capitalized, $0.value) })
            }
        }
    }

    private func usagePanel(_ title: String, rows: [(String, Int)]) -> some View {
        let total = max(rows.reduce(0) { $0 + $1.1 }, 1)
        let sorted = rows.sorted { $0.1 > $1.1 }.prefix(8)
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            if sorted.isEmpty {
                Text("Nothing yet.").foregroundStyle(Theme.secondary)
            }
            ForEach(Array(sorted), id: \.0) { name, count in
                let frac = Double(count) / Double(total)
                HStack(spacing: 12) {
                    Text(name).font(.system(size: 13)).foregroundStyle(Theme.text).frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.window)
                            RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.75)).frame(width: max(g.size.width * frac, 4))
                            Text("\(Int(frac * 100))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.leading, 8)
                        }
                    }
                    .frame(height: 26)
                    Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}
