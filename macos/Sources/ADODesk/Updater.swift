import AppKit
import CryptoKit
import Security

/// A GitHub release ADO Desk can update to.
struct Release: Equatable {
    /// "0.3.3": the tag without its "v".
    let version: String
    /// The release's page, for its notes.
    let page: URL
    /// ADO-Desk-<version>.zip, the signed app.
    let zip: URL
    /// SHA256SUMS, which lists the zip's checksum.
    let checksums: URL
}

/// Check for Updates…: asks GitHub for the latest release and, when it is newer, downloads it, checks its checksum
/// and that it is signed with the same certificate as the running copy, swaps it in once ADO Desk has quit, and opens
/// it again. Files the app downloads itself get no quarantine flag, so Gatekeeper doesn't stop the new copy as it would
/// a browser download of a self-signed app, and the same certificate keeps Keychain access to the token.
enum Updater {
    static let latestRelease = URL(string: "https://api.github.com/repos/jsonify/ado-desk/releases/latest")!

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Release data

    /// Whether `version` is newer than `current`, part by part ("0.3.10" is newer than "0.3.9"; a missing part
    /// counts as 0). Anything that isn't a version, like a "dev" build, is never newer and never updated.
    static func isNewer(_ version: String, than current: String) -> Bool {
        guard let a = parts(version), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int]? {
        let digits = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// The release in GitHub's "latest release" JSON; nil for a draft, a pre-release, or one whose zip and checksums
    /// aren't attached yet (the release build adds them a few minutes after the release appears).
    static func release(fromJSON data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let zip = asset("ADO-Desk-\(version).zip"), let checksums = asset("SHA256SUMS") else { return nil }
        return Release(version: version, page: page, zip: zip, checksums: checksums)
    }

    /// `file`'s checksum in a SHA256SUMS file (`shasum -a 256` lines: "<hex>  <name>", or "<hex> *<name>").
    static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name == file { return fields[0].lowercased() }
        }
        return nil
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// "0.2.0 (412, 48db438)": the version, build number and git commit build_app.sh stamps in from git; "dev" for
    /// `swift run`, which has no Info.plist.
    static func versionLine(_ info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let details = [info?["CFBundleVersion"], info?["ADODeskCommit"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        return details.isEmpty ? short : "\(short) (\(details.joined(separator: ", ")))"
    }

    // MARK: Checking

    @MainActor private static var timer: Timer?
    @MainActor private static var busy = false
    /// The version the user answered Later for: the daily check doesn't ask about it again until ADO Desk restarts.
    @MainActor private static var postponed: String?

    /// Checks a minute after launch and then once a day, while Settings → Updates → Check for updates
    /// automatically is on. Call again when that setting changes.
    @MainActor static func start() {
        timer?.invalidate()
        timer = nil
        guard SettingsStore.shared.checkForUpdates else { return }
        let t = Timer(fire: Date().addingTimeInterval(60), interval: 24 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in check(userInitiated: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Looks for a newer release and offers it. Only a check the user asked for says when there is nothing new or
    /// the check failed.
    @MainActor static func check(userInitiated: Bool) {
        guard !busy else { return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                var request = URLRequest(url: latestRelease)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let latest = release(fromJSON: data) else {
                    throw Failure("GitHub didn't list a release to update to. Try again in a few minutes.")
                }
                guard isNewer(latest.version, than: current) else {
                    if userInitiated { tell("ADO Desk is up to date", "Version \(current) is the newest.") }
                    return
                }
                // Don't interrupt an open sheet or dialog with an update nobody asked about.
                if !userInitiated && (postponed == latest.version || NSApp.modalWindow != nil) { return }
                await offer(latest, current: current)
            } catch {
                if userInitiated { tell("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    @MainActor private static func offer(_ release: Release, current: String) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ADO Desk \(release.version) is available"
        alert.informativeText = "You have \(current). ADO Desk downloads the update, checks it, replaces itself and "
            + "opens again. Your settings and the token in the Keychain stay."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try await install(release) } catch { tell("Couldn't install the update", error.localizedDescription) }
        case .alertThirdButtonReturn:
            postponed = release.version
            NSWorkspace.shared.open(release.page)
        default:
            postponed = release.version
        }
    }

    @MainActor private static func tell(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Installing

    @MainActor private static func install(_ release: Release) async throws {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure("ADO Desk can't replace itself in \(folder.path). Install the update with the command in "
                + "the README instead.")
        }
        let requirement = try ownRequirement()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ADO-Desk-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            async let zipData = download(release.zip)
            async let sumsData = download(release.checksums)
            let (zip, sums) = try await (zipData, sumsData)
            guard let expected = checksum(for: release.zip.lastPathComponent, in: String(decoding: sums, as: UTF8.self)),
                  expected == sha256(zip) else {
                throw Failure("The download doesn't match its checksum, so it wasn't installed.")
            }
            let zipFile = work.appendingPathComponent(release.zip.lastPathComponent)
            try zip.write(to: zipFile)
            try await unzip(zipFile, into: work)
            let new = work.appendingPathComponent("ADO Desk.app")
            try verify(new, meets: requirement)
            try relaunch(replacing: app, with: new, work: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Downloading \(url.lastPathComponent) failed.")
        }
        return data
    }

    private static func unzip(_ zip: URL, into folder: URL) async throws {
        let (zipPath, folderPath) = (zip.path, folder.path)
        let status = await Task.detached { () -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zipPath, folderPath]
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        guard status == 0 else { throw Failure("The download couldn't be unpacked.") }
    }

    /// The running copy's designated requirement: for a release, its bundle ID and the certificate it was signed
    /// with, which is also what the Keychain ties access to the token to.
    private static func ownRequirement() throws -> SecRequirement {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("ADO Desk couldn't read its own signature.")
        }
        // An ad-hoc signature (a local build) requires its own exact code, which no other build has.
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text, (text as String).contains("cdhash") {
            throw Failure("This copy of ADO Desk isn't signed with the release certificate, so it can't tell a genuine "
                + "update from another app. Download the update from the Releases page instead.")
        }
        return requirement
    }

    private static func verify(_ app: URL, meets requirement: SecRequirement) throws {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The update isn't signed with the same certificate as this copy of ADO Desk, so it wasn't "
                + "installed.")
        }
    }

    /// Hands the swap to a shell that waits for ADO Desk to quit, moves the old copy aside (and back if the new one
    /// can't take its place), opens the result and cleans up. Then quits.
    @MainActor private static func relaunch(replacing app: URL, with new: URL, work: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            mv "$2" "$4/ADO Desk-old.app" && { mv "$3" "$2" || mv "$4/ADO Desk-old.app" "$2"; }
            open "$2"
            rm -rf "$4"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(getpid()), app.path, new.path, work.path]
        try p.run()
        NSApp.terminate(nil)
    }
}
