import AppKit
import SwiftUI

enum HomeSection: String, CaseIterable, Identifiable {
    case meet, uses, saved, models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meet: "Meet Lina"
        case .uses: "What she's good at"
        case .saved: "Saved"
        case .models: "Models & skills"
        }
    }

    var symbol: String {
        switch self {
        case .meet: "face.smiling"
        case .uses: "play.rectangle"
        case .saved: "tray.full"
        case .models: "cpu"
        }
    }
}

/// Which page Lina's window shows; `/lina saved` opens it on Saved.
@MainActor
final class HomeNavigation: ObservableObject {
    static let shared = HomeNavigation()
    @Published var section: HomeSection? = .meet
}

/// Lina's window: who she is, what she can do (animated), what she has saved, and the models behind her.
struct HomeView: View {
    @ObservedObject var engine: LinaEngine
    @ObservedObject var nav = HomeNavigation.shared

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    LinaFace(mood: engine.mood, animated: true)
                        .frame(width: 92, height: 92)
                    Text(engine.mood.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(engine.mood.hair)
                }
                .padding(.top, 18)
                .padding(.bottom, 10)
                List(selection: $nav.section) {
                    ForEach(HomeSection.allCases) { s in
                        Label(s.title, systemImage: s.symbol).tag(Optional(s))
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                Group {
                    switch nav.section ?? .meet {
                    case .meet: MeetLinaPage(engine: engine)
                    case .uses: UseCasesPage()
                    case .saved: SavedPage()
                    case .models: ModelsPage()
                    }
                }
                .padding(28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

// MARK: - Meet Lina

private struct MeetLinaPage: View {
    @ObservedObject var engine: LinaEngine
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 28) {
                TimelineView(.periodic(from: .now, by: 2.2)) { tl in
                    let moods = Mood.allCases
                    let i = Int(tl.date.timeIntervalSinceReferenceDate / 2.2) % moods.count
                    LinaFace(mood: moods[i], animated: true)
                        .frame(width: 170, height: 170)
                        .animation(Theme.spring, value: i)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Meet Lina.")
                        .font(Theme.serif(38, weight: .semibold))
                    Text("She lives at your cursor in every app, and speaks only when you ask. Type /lina anywhere and a small bar opens: ask, press Return, and her answer waits for your ⌘1.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Try it in TextEdit") { TryIt.openTextEdit() }
                            .buttonStyle(InkButtonStyle())
                        Button("Show tips again") { engine.tips.reset() }
                            .buttonStyle(InkButtonStyle(prominent: false))
                    }
                    .padding(.top, 4)
                }
            }

            rule

            VStack(alignment: .leading, spacing: 12) {
                Text("Her hair tells you what she's doing").font(Theme.serif(20, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                    ForEach(Mood.allCases) { mood in
                        HStack(alignment: .top, spacing: 12) {
                            LinaFace(mood: mood, head: true).frame(width: 40, height: 41)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mood.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(mood.hair)
                                Text(mood.meaning).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Everything she understands").font(Theme.serif(20, weight: .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CommandParser.words) { w in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(w.usage)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 230, alignment: .leading)
                            Text(w.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("/lina <any question> ↩")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 230, alignment: .leading)
                        Text("Searches the web and answers in words that fit your sentence.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(settings.hotKey == .off ? "—" : settings.hotKey.title)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 230, alignment: .leading)
                        Text("Opens the same bar, without typing /lina.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
            }
        }
    }

    private var rule: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "hand.raised.fingers.spread")
                .font(.system(size: 22))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your words stay yours.").font(.system(size: 14, weight: .semibold))
                Text("Lina never types into your text on her own. Fixes sit above your mistakes and answers wait in a card until you press ⌘1, ⌘2… (⌘A takes every fix). Esc leaves everything as you wrote it, and ⌘Z undoes a choice.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.07)))
    }
}

// MARK: - Use cases

private struct UseCasesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What she's good at").font(Theme.serif(30, weight: .semibold))
                Text("Six moments where Lina earns her place. Each one plays on a loop; try the line under it in any app (↩ means press Return in the bar).")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ForEach(UseCase.all) { useCase in
                UseCaseRow(useCase: useCase)
                Divider()
            }
        }
    }
}

struct UseCaseRow: View {
    let useCase: UseCase

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(useCase.who.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.ink)
                Text(useCase.title).font(Theme.serif(22, weight: .semibold))
                Text(useCase.pitch)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TRY TYPING").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                    Text(useCase.tryIt)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }
                .padding(.top, 4)
            }
            .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
            DemoPlayer(useCase: useCase)
        }
    }
}

// MARK: - Saved

private struct SavedPage: View {
    @ObservedObject var history = History.shared
    @State private var query = ""
    @State private var kind: HistoryItem.Kind?
    @State private var confirmClear = false

    private var shown: [HistoryItem] {
        history.items.filter { item in
            (kind == nil || item.kind == kind)
                && (query.isEmpty || item.prompt.localizedCaseInsensitiveContains(query)
                    || item.result.localizedCaseInsensitiveContains(query))
        }
    }

    private var emptyTitle: String { history.items.isEmpty ? "Nothing saved yet" : "No matches" }

    private var emptyDetail: String {
        history.items.isEmpty
            ? "Ask Lina something with /lina in any app. Searches, questions, rewrites and pictures appear here."
            : "Try other words."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved").font(Theme.serif(30, weight: .semibold))
                    Text("Every search, question, rewrite and picture, kept only on this Mac.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                if !history.items.isEmpty {
                    Button("Clear All…", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete everything Lina has saved?", isPresented: $confirmClear) {
                            Button("Delete All", role: .destructive) { history.clear() }
                        } message: {
                            Text("This removes \(history.items.count) items and their pictures from this Mac.")
                        }
                }
            }
            HStack(spacing: 10) {
                TextField("Search saved", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("Kind", selection: $kind) {
                    Text("All").tag(HistoryItem.Kind?.none)
                    ForEach(HistoryItem.Kind.allCases, id: \.self) { k in Text(k.title).tag(Optional(k)) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            if shown.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyDetail))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { item in SavedRow(item: item) }
                }
            }
        }
    }
}

private struct SavedRow: View {
    let item: HistoryItem
    @ObservedObject var history = History.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.ink.opacity(0.1)))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.kind.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.date, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.secondary)
                    if !item.app.isEmpty {
                        Text("· \(item.app)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if item.inserted {
                        Label("Inserted", systemImage: "checkmark").font(.system(size: 10.5)).foregroundStyle(Mood.happy.hair)
                    }
                }
                Text(item.prompt)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .textSelection(.enabled)
                if item.kind == .image, let image = history.image(for: item) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(item.result)
                        .font(Theme.serif(14.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.sources.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.sources, id: \.self) { s in
                            if let url = URL(string: s.url) {
                                Link(s.site, destination: url).font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .contextMenu {
            Button("Copy Answer") { TextInserter.copy(item.result) }
            Button("Copy Question") { TextInserter.copy(item.prompt) }
            Divider()
            Button("Delete", role: .destructive) { history.delete(item.id) }
        }
    }
}

// MARK: - Models & skills

private struct ModelsPage: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Models & skills").font(Theme.serif(30, weight: .semibold))
                Text("The minds behind Lina. Type /lina model in any app to switch on the spot.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                provider(title: "Nebius Token Factory", symbol: "bolt.horizontal.circle",
                         ready: settings.hasNebiusKey, active: settings.provider == .nebius,
                         rows: [("Commands", settings.commandModel), ("Sentence checks", settings.checkModel),
                                ("Pictures", settings.imageModel)])
                provider(title: "Google Search via Gemini", symbol: "globe",
                         ready: settings.hasSearch, active: settings.hasSearch,
                         rows: [("Model", settings.geminiModel),
                                ("Key", settings.hasSearch ? "Set" : "Add GEMINI_API_KEY to .env or Settings → Search")])
                provider(title: "On this Mac", symbol: "desktopcomputer",
                         ready: true, active: settings.provider == .local,
                         rows: [("Server", settings.localBaseURL), ("Model", settings.localModel)])
            }
            HStack {
                Spacer()
                Button("Open Settings…") { WindowOpener.shared.settings() }
                    .buttonStyle(InkButtonStyle(prominent: false))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Skills & plug-ins").font(Theme.serif(20, weight: .semibold))
                    Text("COMING LATER").font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Mood.found.hair.opacity(0.18)))
                        .foregroundStyle(Mood.found.hair)
                }
                Text("Skills will teach Lina new /lina commands; plug-ins will connect her to the places your notes live.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    planned("/lina cite", "Find a source for a claim and format the citation.", "quote.opening")
                    planned("/lina translate", "Translate the paragraph and keep your tone.", "character.bubble")
                    planned("Your style guide", "Teach Lina the words and rules your team uses.", "text.book.closed")
                    planned("Notion & Google Docs", "Search your own notes, not just the web.", "square.stack.3d.up")
                }
            }
        }
    }

    private func provider(title: String, symbol: String, ready: Bool, active: Bool, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.ink)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(active ? "In use" : ready ? "Ready" : "Not set up")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill((active ? Mood.happy.hair : ready ? Theme.ink : Mood.worried.hair).opacity(0.15)))
                    .foregroundStyle(active ? Mood.happy.hair : ready ? Theme.ink : Mood.worried.hair)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
                    Text(row.1).font(.system(size: 12, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func planned(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .opacity(0.8)
    }
}

/// Opens a practice page in TextEdit, so trying Lina is one click away.
@MainActor
enum TryIt {
    static func openTextEdit() {
        let file = History.shared.folder.appendingPathComponent("Try Lina.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            let text = """
            Try Lina here. Lina only answers when you ask.

            1. Finish this sentence with a dot and watch for a card: Thank you for you're help, I realy apreciate it

            2. Ask the web mid-sentence. Type the start, then /lina, then your question in the bar and Return: The tallest mountain in Africa is /lina which mountain and how tall

            3. Ask for a question about your thinking. After a thought, type /lina and press Return: I keep putting off this decision because

            4. Switch models: /lina model

            """
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: config, completionHandler: nil)
    }
}
