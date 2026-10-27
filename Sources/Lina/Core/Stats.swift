import Foundation
import Combine

/// Local-only writing stats. Never leaves the Mac.
@MainActor
final class WritingStats: ObservableObject {
    static let shared = WritingStats()

    struct Day: Codable { var words = 0; var accepted = 0; var shown = 0 }

    @Published private(set) var days: [String: Day] = [:]
    private let key = "stats.days"
    private var saveTimer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = decoded
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var todayKey: String { Self.fmt.string(from: Date()) }

    var today: Day { days[todayKey] ?? Day() }

    /// Consecutive days (ending today or yesterday) with at least 50 words.
    var streak: Int {
        var n = 0
        var date = Date()
        if (days[Self.fmt.string(from: date)]?.words ?? 0) < 50 {
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        while (days[Self.fmt.string(from: date)]?.words ?? 0) >= 50 {
            n += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        return n
    }

    /// Words for each of the last `n` days, oldest first.
    func lastDays(_ n: Int) -> [(label: String, words: Int)] {
        let cal = Calendar.current
        let short = DateFormatter()
        short.dateFormat = "EEEEE"
        return (0..<n).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date())!
            return (short.string(from: date), days[Self.fmt.string(from: date)]?.words ?? 0)
        }
    }

    func addWords(_ n: Int) { mutate { $0.words += n } }
    func suggestionShown() { mutate { $0.shown += 1 } }
    func suggestionAccepted(words: Int) { mutate { $0.accepted += 1; $0.words += words } }

    func reset() {
        days = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func mutate(_ f: (inout Day) -> Void) {
        var d = today
        f(&d)
        days[todayKey] = d
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
