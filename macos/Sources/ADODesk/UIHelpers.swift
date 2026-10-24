import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Format {
    static let ymd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "2025-01-06T00:00:00Z" → "2025-01-06"
    static func day(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        return String(iso.prefix(10))
    }

    /// "2025-01-06T14:03:22.1Z" → "2025-01-06 14:03"
    static func minute(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    static func points(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Non-empty, trimmed lines (used for acceptance criteria input).
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
    }

    /// Rough HTML → text for displaying ADO rich-text fields.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|h[1-6]|pre|ul|ol)>", "\n"),
            ("(?i)<li[^>]*>", "• "),
            ("(?i)</li>", "\n"),
            ("<[^>]+>", ""),
        ]
        for (pattern, template) in patterns {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmed
    }
}

enum WebLinks {
    static func workItem(org: String?, project: String?, id: Int) -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let org, let project, let encoded = project.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "\(org)/\(encoded)/_workitems/edit/\(id)"
    }
}

enum Desktop {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func chooseFile(allowedTypes: [UTType] = []) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Tracks one async engine call for a view: busy flag plus the last error.
@MainActor
final class TaskState: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}

// MARK: - Shared views

struct RunButton: View {
    let title: String
    let systemImage: String
    let isRunning: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, isRunning: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isRunning = isRunning
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .disabled(isRunning)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
    }
}

struct SuccessLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .foregroundStyle(Color.green)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
