import Combine
import Foundation
import Security

/// Connection and engine settings. Plain values live in UserDefaults; the PAT lives in the Keychain.
/// Blank values are not passed to the engine, so ado_cli.py's own .env / environment fallback still applies.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let org = "ado.org"
        static let project = "ado.project"
        static let team = "ado.team"
        static let assignee = "ado.assignee"
        static let areaPath = "ado.areaPath"
        static let iterationPath = "ado.iterationPath"
        static let pythonPath = "engine.pythonPath"
        static let scriptPath = "engine.scriptPath"
        static let envFile = "engine.envFile"
        static let sslCertFile = "engine.sslCertFile"
    }

    private let defaults: UserDefaults

    @Published var org: String { didSet { defaults.set(org, forKey: Keys.org) } }
    @Published var project: String { didSet { defaults.set(project, forKey: Keys.project) } }
    @Published var team: String { didSet { defaults.set(team, forKey: Keys.team) } }
    @Published var assignee: String { didSet { defaults.set(assignee, forKey: Keys.assignee) } }
    @Published var areaPath: String { didSet { defaults.set(areaPath, forKey: Keys.areaPath) } }
    @Published var iterationPath: String { didSet { defaults.set(iterationPath, forKey: Keys.iterationPath) } }
    @Published var pythonPath: String { didSet { defaults.set(pythonPath, forKey: Keys.pythonPath) } }
    @Published var scriptPath: String { didSet { defaults.set(scriptPath, forKey: Keys.scriptPath) } }
    @Published var envFile: String { didSet { defaults.set(envFile, forKey: Keys.envFile) } }
    @Published var sslCertFile: String { didSet { defaults.set(sslCertFile, forKey: Keys.sslCertFile) } }
    @Published private(set) var hasToken: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        org = defaults.string(forKey: Keys.org) ?? ""
        project = defaults.string(forKey: Keys.project) ?? ""
        team = defaults.string(forKey: Keys.team) ?? ""
        assignee = defaults.string(forKey: Keys.assignee) ?? ""
        areaPath = defaults.string(forKey: Keys.areaPath) ?? ""
        iterationPath = defaults.string(forKey: Keys.iterationPath) ?? ""
        pythonPath = defaults.string(forKey: Keys.pythonPath) ?? ""
        scriptPath = defaults.string(forKey: Keys.scriptPath) ?? ""
        envFile = defaults.string(forKey: Keys.envFile) ?? ""
        sslCertFile = defaults.string(forKey: Keys.sslCertFile) ?? ""
        hasToken = Keychain.readToken() != nil
    }

    /// True when nothing is configured in the app; the engine may still find a .env file.
    var looksUnconfigured: Bool {
        org.trimmed.isEmpty && project.trimmed.isEmpty && envFile.trimmed.isEmpty && !hasToken
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let saved = Keychain.saveToken(token.trimmed)
        hasToken = Keychain.readToken() != nil
        return saved
    }

    func clearToken() {
        Keychain.deleteToken()
        hasToken = false
    }

    /// Environment variables understood by ado_cli.py's load_config().
    func engineEnvironment() -> [String: String] {
        let pairs: [(String, String)] = [
            ("ADO_ORG", org),
            ("ADO_PROJECT", project),
            ("ADO_TEAM", team),
            ("ADO_ASSIGNEE", assignee),
            ("ADO_AREA_PATH", areaPath),
            ("ADO_ITERATION_PATH", iterationPath),
            ("ADO_ENV_FILE", Self.expand(envFile)),
            ("SSL_CERT_FILE", Self.expand(sslCertFile)),
        ]
        var environment: [String: String] = [:]
        for (key, value) in pairs where !value.trimmed.isEmpty {
            environment[key] = value.trimmed
        }
        if let token = Keychain.readToken(), !token.isEmpty {
            environment["ADO_TOKEN"] = token
        }
        return environment
    }

    /// The engine script: explicit setting, then the copy bundled in the .app, then the repo checkout.
    var resolvedScriptURL: URL? {
        let fileManager = FileManager.default
        if !scriptPath.trimmed.isEmpty {
            let path = Self.expand(scriptPath)
            return fileManager.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let bundled = Bundle.main.url(forResource: "ado_cli", withExtension: "py") {
            return bundled
        }
        // Development (`swift run`): walk up from this source file to the repository root.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("ado_cli.py")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// Where the engine runs, so relative paths it writes land somewhere predictable.
    func workingDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("ADODesk", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func expand(_ path: String) -> String {
        (path.trimmed as NSString).expandingTildeInPath
    }
}

enum Keychain {
    private static let service = "ADODesk"
    private static let account = "azure-devops-pat"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        deleteToken()
        guard !token.isEmpty else { return true }
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
