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

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// The calendar day of an ADO timestamp. Iteration dates are midnight UTC, so the time is ignored.
    static func date(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        return ymd.date(from: String(iso.prefix(10)))
    }

    /// "2025-01-06T00:00:00Z" → "Jan 6"
    static func shortDay(_ iso: String?) -> String {
        guard let date = date(iso) else { return "—" }
        return monthDay.string(from: date)
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

    /// Puts HTML on the pasteboard with RTF and plain-text fallbacks, so mail apps paste it formatted.
    @MainActor
    static func copyRich(html: String, plain: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        if let attributed = attributedString(fromHTML: html),
           let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(plain, forType: .string)
    }

    /// Opens a new message in the default mail app with the HTML as its body. Returns false if none can compose.
    @MainActor @discardableResult
    static func composeEmail(subject: String, html: String) -> Bool {
        guard let service = NSSharingService(named: .composeEmail),
              let body = attributedString(fromHTML: html),
              service.canPerform(withItems: [body])
        else { return false }
        service.subject = subject
        service.perform(withItems: [body])
        return true
    }

    private static func attributedString(fromHTML html: String) -> NSAttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try? NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }

    static func chooseSaveLocation(defaultName: String, types: [UTType] = [.json]) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
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

struct WorkItemTypeIcon: View {
    let type: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 16)
            .help(type)
    }

    private var symbol: String {
        switch type {
        case "Bug": return "ladybug.fill"
        case "Task": return "checkmark.square.fill"
        case "Feature": return "trophy.fill"
        case "Epic": return "crown.fill"
        default: return "book.fill"
        }
    }

    private var color: Color {
        switch type {
        case "Bug": return .red
        case "Task": return .yellow
        case "Feature": return .purple
        case "Epic": return .orange
        default: return .blue
        }
    }
}

struct StateBadge: View {
    let state: String

    var body: some View {
        Text(state)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case "Active", "Committed", "In Progress": return .blue
        case "Resolved": return .teal
        case "Closed", "Done": return .green
        case "Removed": return .gray
        default: return .secondary
        }
    }
}

extension View {
    /// Tints a field that differs from its saved value.
    func changedHighlight(_ changed: Bool) -> some View {
        // Drawn outside the field's frame so toggling it doesn't move the layout.
        background(
            RoundedRectangle(cornerRadius: 6)
                .fill(changed ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(-4)
        )
    }
}
