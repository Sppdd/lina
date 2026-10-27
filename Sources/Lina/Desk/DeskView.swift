import SwiftUI
import AppKit

/// Remembers the Desk's live text view so the palette can work on it.
@MainActor
final class DeskRegistry: ObservableObject {
    static let shared = DeskRegistry()
    weak var textView: DeskTextView?
    @Published var thinking = false
    @Published var lastError: String?

    var activeTarget: WritingTarget? {
        guard let tv = textView, let w = tv.window, w.isKeyWindow || w.isMainWindow, NSApp.isActive else { return nil }
        return DeskTarget(tv)
    }
}

struct DeskView: View {
    @ObservedObject var store = DeskStore.shared
    @ObservedObject var registry = DeskRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stats = WritingStats.shared
    @AppStorage("desk.focus") private var focusMode = false
    @AppStorage("desk.typewriter") private var typewriter = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    var openPalette: () -> Void

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let page = store.current {
                editor(page)
            } else {
                ContentUnavailableView("No page", systemImage: "doc.text", description: Text("Create a page to start writing."))
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $store.selection) {
            Section {
                ForEach(store.pages) { page in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.title)
                            .font(Theme.serif(14, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(page.modified, format: .relative(presentation: .named))
                            Text("·")
                            Text("\(page.words) words")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        if !page.preview.isEmpty {
                            Text(page.preview)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(page.id)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: page.id)])
                        }
                        Button("Copy Text") { TextInserter.copy(page.text) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { store.delete(page.id) }
                    }
                }
            } header: {
                todayHeader
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { store.create() } label: { Label("New Page", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Page (⌘N)")
            }
        }
    }

    private var todayHeader: some View {
        let words = stats.today.words
        let goal = max(1, settings.dailyGoal)
        return HStack(spacing: 10) {
            ProgressRing(progress: Double(words) / Double(goal), lineWidth: 3)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(words) of \(goal) words today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                if stats.streak > 0 {
                    Text("\(stats.streak)-day streak")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Editor

    private func editor(_ page: Page) -> some View {
        DeskEditor(page: page, focusMode: focusMode, typewriter: typewriter)
            .id(page.id)
            .ignoresSafeArea(.container, edges: .top)
            .background(Theme.paper)
            .overlay(alignment: .bottom) { statusBar(page) }
            .navigationTitle(page.title)
            .navigationSubtitle("\(page.words) words · \(max(1, page.words / 230)) min read")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $focusMode) { Label("Focus", systemImage: "eye") }
                        .help("Focus: dim everything but the paragraph you're in")
                    Toggle(isOn: $typewriter) { Label("Typewriter", systemImage: "text.aligncenter") }
                        .help("Typewriter: keep the line you're writing in the middle")
                    Button(action: openPalette) { Label("Ask Lina", systemImage: "pencil.and.scribble") }
                        .help("Ask Lina (\(settings.hotKey.title))")
                    ShareLink(item: page.text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
    }

    private func statusBar(_ page: Page) -> some View {
        HStack(spacing: 8) {
            if registry.thinking {
                InkDot().frame(width: 6, height: 6)
                Text("Lina is reading along…")
            } else if let err = registry.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).lineLimit(1)
            } else {
                Text("⇥ keep  ·  esc dismiss  ·  \(settings.hotKey.title) ask Lina")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 14)
        .animation(Theme.quick, value: registry.thinking)
    }
}

/// A circular progress ring in the style of Activity.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.001, progress)))
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.spring, value: progress)
        }
    }
}

// MARK: - Editor bridge

struct DeskEditor: NSViewRepresentable {
    let page: Page
    var focusMode: Bool
    var typewriter: Bool

    func makeCoordinator() -> Coordinator { Coordinator(pageID: page.id) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = DeskTextView.make()
        tv.load(page.text)
        tv.focusMode = focusMode
        tv.typewriter = typewriter
        context.coordinator.attach(tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.centerCaret(animated: false)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? DeskTextView else { return }
        if tv.focusMode != focusMode { tv.focusMode = focusMode }
        if tv.typewriter != typewriter { tv.typewriter = typewriter }
    }

    @MainActor
    final class Coordinator {
        let pageID: UUID
        weak var textView: DeskTextView?
        private var task: Task<Void, Never>?
        private var lastWordCount: Int?

        init(pageID: UUID) { self.pageID = pageID }

        func attach(_ tv: DeskTextView) {
            textView = tv
            DeskRegistry.shared.textView = tv
            lastWordCount = WordCount.count(tv.cleanString)
            tv.onTextChange = { [weak self] text in
                guard let self else { return }
                DeskStore.shared.update(self.pageID, text: text)
                self.task?.cancel()
                DeskRegistry.shared.thinking = false
                // Count newly written words toward today's goal.
                let n = WordCount.count(text)
                if let last = self.lastWordCount, n > last { WritingStats.shared.addWords(n - last) }
                self.lastWordCount = n
            }
            tv.onPause = { [weak self] in self?.suggest() }
        }

        private func suggest() {
            let settings = AppSettings.shared
            guard let tv = textView, settings.enabled, settings.isModelConfigured,
                  tv.ghostRange == nil, tv.selectedRange().length == 0 else { return }
            let ns = tv.string as NSString
            let loc = tv.selectedRange().location
            let before = ns.substring(to: loc)
            let after = ns.substring(from: loc)
            guard Suggestion.isGoodMoment(before: before, after: after) else { return }

            let ctx = WritingContext(before: before, after: after, appName: "Lina Desk")
            let messages = Prompts.continuation(ctx, voice: settings.voice, aboutMe: settings.aboutMe, length: settings.length)
            let client = LLMClient(endpoint: settings.endpoint)
            let length = settings.length
            task?.cancel()
            DeskRegistry.shared.thinking = true
            DeskRegistry.shared.lastError = nil
            task = Task { [weak self, weak tv] in
                defer { if !Task.isCancelled { DeskRegistry.shared.thinking = false } }
                do {
                    let raw = try await client.complete(messages, maxTokens: length.maxTokens + 8, temperature: 0.45, stop: ["\n\n"])
                    guard !Task.isCancelled, let tv, self != nil,
                          tv.selectedRange().location == loc, (tv.string as NSString).length == ns.length else { return }
                    let text = Suggestion.clean(raw, before: before, length: length)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        tv.showGhost(text)
                        WritingStats.shared.suggestionShown()
                    }
                } catch is CancellationError {
                } catch let e as URLError where e.code == .cancelled {
                } catch {
                    DeskRegistry.shared.lastError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Palette target

@MainActor
final class DeskTarget: WritingTarget {
    private weak var tv: DeskTextView?

    init(_ tv: DeskTextView) {
        tv.clearGhost()
        self.tv = tv
    }

    var displayName: String { "Desk" }
    var icon: NSImage? { NSApp.applicationIconImage }
    var canWrite: Bool { tv != nil }
    var hasSelection: Bool { (tv?.selectedRange().length ?? 0) > 0 }

    private var ns: NSString { (tv?.string ?? "") as NSString }

    private var focusRange: NSRange {
        guard let tv else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        var r = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        if r.length > 0, ns.substring(with: r).hasSuffix("\n") { r.length -= 1 }
        return r
    }

    var focusText: String { ns.substring(with: focusRange) }

    var context: WritingContext {
        guard let tv else { return WritingContext(before: "") }
        let loc = min(tv.selectedRange().location, ns.length)
        return WritingContext(before: ns.substring(to: loc), after: ns.substring(from: loc),
                              selection: focusText, appName: "Lina Desk")
    }

    func restore() {
        tv?.window?.makeKeyAndOrderFront(nil)
        if let tv { tv.window?.makeFirstResponder(tv) }
    }

    func replaceFocus(with text: String) {
        let r = focusRange
        restore()
        tv?.insertText(text, replacementRange: r)
    }

    func insertAfterFocus(_ text: String) {
        guard let tv else { return }
        let end = hasSelection ? NSMaxRange(tv.selectedRange()) : tv.selectedRange().location
        let joined = Suggestion.joinSpacing(text, before: ns.substring(to: end))
        restore()
        tv.insertText(joined, replacementRange: NSRange(location: end, length: 0))
    }
}
