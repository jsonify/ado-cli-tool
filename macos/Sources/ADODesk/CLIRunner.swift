import Combine
import Foundation

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let arguments: [String]
    let exitCode: Int32?
    let duration: TimeInterval
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    var subcommand: String { arguments.first ?? "" }
    var commandLine: String {
        (["ado_cli.py"] + arguments.map(Self.shellQuoted)).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=./:,@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs ado_cli.py as a subprocess and decodes its JSON envelope.
@MainActor
final class CLIRunner: ObservableObject {
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var runningCount = 0

    private let settings: SettingsStore
    private let maxLogEntries = 200

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    /// Runs a command and returns its decoded `result`.
    func run<T: Decodable>(_ arguments: [String], as type: T.Type = T.self) async throws -> T {
        let envelope = try await runEnvelope(arguments, as: type)
        guard let result = envelope.result else {
            throw CLIFailure(code: "DECODE_ERROR", message: "The engine returned no result.")
        }
        return result
    }

    /// Runs a command and returns the full envelope (useful for organization/project metadata).
    func runEnvelope<T: Decodable>(_ arguments: [String], as type: T.Type = T.self) async throws -> Envelope<T> {
        let output = try await execute(arguments)
        let decoder = JSONDecoder()

        guard let generic = try? decoder.decode(Envelope<JSONValue>.self, from: output.stdout) else {
            // argparse errors and Python crashes land on stderr without an envelope.
            let detail = [output.stderrText, output.stdoutText].first { !$0.isEmpty } ?? "Exit code \(output.status)"
            throw CLIFailure(code: "ENGINE_ERROR", message: detail)
        }
        guard generic.success else {
            throw CLIFailure(
                code: generic.error?.code ?? "UNKNOWN_ERROR",
                message: generic.error?.message ?? "The command failed without an error message."
            )
        }
        do {
            return try decoder.decode(Envelope<T>.self, from: output.stdout)
        } catch {
            throw CLIFailure(code: "DECODE_ERROR", message: "Unexpected response from the engine: \(error)")
        }
    }

    /// Runs the engine with raw arguments and records the call in the activity log.
    func execute(_ arguments: [String]) async throws -> ProcessOutput {
        let invocation = try makeInvocation(arguments)
        runningCount += 1
        defer { runningCount -= 1 }

        let started = Date()
        do {
            let output = try await ProcessExecutor.run(invocation)
            record(LogEntry(
                date: started,
                arguments: arguments,
                exitCode: output.status,
                duration: Date().timeIntervalSince(started),
                stdout: output.stdoutText,
                stderr: output.stderrText
            ))
            return output
        } catch {
            record(LogEntry(
                date: started,
                arguments: arguments,
                exitCode: nil,
                duration: Date().timeIntervalSince(started),
                stdout: "",
                stderr: error.localizedDescription
            ))
            throw CLIFailure(code: "ENGINE_LAUNCH_FAILED", message: error.localizedDescription)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    private func record(_ entry: LogEntry) {
        log.insert(entry, at: 0)
        if log.count > maxLogEntries {
            log.removeLast(log.count - maxLogEntries)
        }
    }

    private func makeInvocation(_ arguments: [String]) throws -> ProcessExecutor.Invocation {
        guard let script = settings.resolvedScriptURL else {
            throw CLIFailure(
                code: "ENGINE_NOT_FOUND",
                message: "Could not locate ado_cli.py. Set its location in Settings → Engine."
            )
        }

        var environment = ProcessInfo.processInfo.environment
        // GUI apps don't inherit the login shell PATH, so add the usual Python locations.
        let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]
        environment["PATH"] = searchPath.filter { !$0.isEmpty }.joined(separator: ":")
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        for (key, value) in settings.engineEnvironment() {
            environment[key] = value
        }

        let python = settings.pythonPath.trimmed
        let executable: URL
        let processArguments: [String]
        if python.isEmpty {
            executable = URL(fileURLWithPath: "/usr/bin/env")
            processArguments = ["python3", script.path] + arguments
        } else {
            executable = URL(fileURLWithPath: (python as NSString).expandingTildeInPath)
            processArguments = [script.path] + arguments
        }

        return ProcessExecutor.Invocation(
            executable: executable,
            arguments: processArguments,
            environment: environment,
            workingDirectory: try settings.workingDirectory()
        )
    }
}

enum ProcessExecutor {
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: URL
    }

    private final class DataBox {
        var data = Data()
    }

    static func run(_ invocation: Invocation) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = invocation.executable
                process.arguments = invocation.arguments
                process.environment = invocation.environment
                process.currentDirectoryURL = invocation.workingDirectory

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes concurrently so a large payload on either can't block the child.
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: ProcessOutput(
                    status: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrBox.data
                ))
            }
        }
    }
}
