import SwiftUI

/// "Report a problem…": the writer picks what's closest and Lina writes the rest from what it saw.
struct ReportView: View {
    static let kinds = [
        "Lina didn't show up", "A card or fix is in the wrong place", "It changed the wrong text",
        "/lina did nothing", "Talking didn't work", "It's slow or got stuck", "I saw an error", "Something else",
    ]

    @State private var kind = ""
    @State private var note = ""
    @State private var saved: URL?
    @State private var failed = false
    @State private var sent: Bool?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What went wrong?").font(Theme.serif(24, weight: .semibold))
                Text("You don't have to explain it well. Pick what's closest, add a few words if you like, and Lina fills in the rest from what it saw: your setup, the text field in front of you, and what it did and decided.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(Self.kinds, id: \.self) { k in
                    let on = k == kind
                    Button { kind = k; saved = nil; sent = nil } label: {
                        Text(k).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(on ? .white : .primary)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(on ? Theme.ink : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("In your own words (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.system(size: 13))
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            if let saved {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Report copied to the clipboard", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if settings.shareReports {
                        switch sent {
                        case nil: Label("Sending it to the Lina team…", systemImage: "arrow.up.circle").foregroundStyle(.secondary)
                        case true?: Label("Sent to the Lina team", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case false?: Label("Couldn't send it: it's still saved on this Mac.", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                        }
                    }
                    Text("Paste it into Claude Code, or just tell Claude: “read my latest Lina report”. It's saved at ~/Library/Logs/Lina/reports/latest.md.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.link)
                }
            } else if failed {
                Label("Lina couldn't save the report.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }

            HStack {
                Text("Tip: type **/lina bug** and a few words right where it went wrong, then press return. Lina captures that exact moment.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Create Report") {
                    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind = kind.isEmpty ? "Not picked" : kind
                    let url = Diagnostics.report(note, kind: kind)
                    saved = url
                    failed = url == nil
                    sent = nil
                    if let url, settings.shareReports {
                        Task { sent = await Cloud.send(reportAt: url, kind: kind, note: note) }
                    }
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
            }

            Toggle("Also send it to the Lina team", isOn: $settings.shareReports)
                .toggleStyle(.checkbox).font(.system(size: 12))

            Text("No document text goes in the report: only app names, lengths, settings and Lina's decisions.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 520)
        .tint(Theme.ink)
    }
}
