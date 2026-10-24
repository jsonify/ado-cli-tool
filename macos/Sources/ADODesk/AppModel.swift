import Combine
import Foundation

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case currentSprint, workItems, sprints, reports

    var id: Self { self }

    var title: String {
        switch self {
        case .currentSprint: return "Current Sprint"
        case .workItems: return "Work Items"
        case .sprints: return "Sprints"
        case .reports: return "Reports"
        }
    }

    var symbol: String {
        switch self {
        case .currentSprint: return "flag.checkered"
        case .workItems: return "checklist"
        case .sprints: return "calendar"
        case .reports: return "square.and.arrow.up"
        }
    }
}

/// A work item the user opened, created or updated, kept so the Work Items list has something to show.
struct RecentItem: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    var state: String
    var type: String
    var lastOpened: Date
}

/// A file written by one of the exports, so it can be found again.
struct RecentExport: Codable, Identifiable, Hashable {
    var id: String { path + "\(date.timeIntervalSince1970)" }
    let kind: String
    let path: String
    let count: Int
    let date: Date
}

/// App-wide navigation and UI state shared by the sidebar, menu commands and the command palette.
@MainActor
final class AppModel: ObservableObject {
    private enum Keys {
        static let recents = "ui.recentItems"
        static let exports = "ui.recentExports"
        static let setupDismissed = "ui.setupDismissed"
    }

    @Published var pane: Pane? = .currentSprint
    @Published var selectedItemID: Int?
    @Published var showNewItem = false
    @Published var showPalette = false
    @Published var showActivity = false
    /// Decided once at launch, so the setup card doesn't vanish as soon as a field is typed in.
    @Published var showSetup: Bool
    @Published var setupDismissed: Bool {
        didSet { defaults.set(setupDismissed, forKey: Keys.setupDismissed) }
    }
    @Published private(set) var recents: [RecentItem]
    @Published private(set) var exports: [RecentExport]
    /// The team's current iteration, once Current Sprint has loaded it; New Work Item offers it.
    @Published var currentIteration: Iteration?

    private let defaults: UserDefaults
    private let maxRecents = 50
    private let maxExports = 20

    init(defaults: UserDefaults = .standard, settings: SettingsStore = .shared) {
        self.defaults = defaults
        let dismissed = defaults.bool(forKey: Keys.setupDismissed)
        setupDismissed = dismissed
        showSetup = settings.looksUnconfigured && !dismissed
        recents = Self.load([RecentItem].self, key: Keys.recents, from: defaults) ?? []
        exports = Self.load([RecentExport].self, key: Keys.exports, from: defaults) ?? []
    }

    func openWorkItem(_ id: Int) {
        pane = .workItems
        selectedItemID = id
    }

    func remember(id: Int, title: String?, state: String?, type: String?) {
        var item = recents.first { $0.id == id }
            ?? RecentItem(id: id, title: "", state: "", type: "", lastOpened: Date())
        if let title { item.title = title }
        if let state { item.state = state }
        if let type { item.type = type }
        item.lastOpened = Date()
        recents.removeAll { $0.id == id }
        recents.insert(item, at: 0)
        if recents.count > maxRecents {
            recents.removeLast(recents.count - maxRecents)
        }
        save(recents, key: Keys.recents)
    }

    func forget(_ id: Int) {
        recents.removeAll { $0.id == id }
        if selectedItemID == id { selectedItemID = nil }
        save(recents, key: Keys.recents)
    }

    func clearRecents() {
        recents.removeAll()
        selectedItemID = nil
        save(recents, key: Keys.recents)
    }

    func recordExport(kind: String, path: String, count: Int) {
        exports.removeAll { $0.path == path }
        exports.insert(RecentExport(kind: kind, path: path, count: count, date: Date()), at: 0)
        if exports.count > maxExports {
            exports.removeLast(exports.count - maxExports)
        }
        save(exports, key: Keys.exports)
    }

    func clearExports() {
        exports.removeAll()
        save(exports, key: Keys.exports)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
