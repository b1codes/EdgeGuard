import Foundation

// MARK: - Shell Executor Protocol

/// A seam for injecting shell execution, enabling unit testing without real processes.
protocol ShellExecutor: Actor {
    /// Runs an executable with the given arguments.
    /// Returns the trimmed stdout on success (exit code 0), or nil on non-zero exit.
    /// Throws only on system-level failures (e.g., executable not found).
    func run(executable: String, arguments: [String]) async throws -> String?
}

// MARK: - System Shell Executor (Production)

actor SystemShellExecutor: ShellExecutor {
    func run(executable: String, arguments: [String]) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit() // blocking; safe because we're off MainActor

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - UC State

/// Snapshot of the current Universal Control system preference state.
/// All booleans reflect user-facing semantics (true = feature is ON).
struct UCState: Sendable {
    /// Whether Universal Control is enabled. Inverse of the `Disable` defaults key.
    var universalControlEnabled: Bool
    /// Whether "Push to connect" (Magic Edges) is enabled. Inverse of `DisableMagicEdges`.
    var magicEdgesEnabled: Bool
    /// Whether Auto-Reconnect is enabled. Inverse of `DisableAutoConnect`.
    var autoReconnectEnabled: Bool
}

// MARK: - Universal Control Service

/// Reads and writes Universal Control system preferences via `defaults` and restarts
/// the background daemon via `pkill`. All operations are serialized through the actor.
actor UniversalControlService {
    private static let domain = "com.apple.universalcontrol"

    private let shell: any ShellExecutor

    init(shell: any ShellExecutor = SystemShellExecutor()) {
        self.shell = shell
    }

    // MARK: - Public Interface

    /// Reads the current state of all Universal Control preferences from the system.
    /// Keys that haven't been written yet default to enabled (Apple ships UC on by default).
    func fetchState() async throws -> UCState {
        let plistOut = try await shell.run(
            executable: "/usr/bin/defaults",
            arguments: ["read", Self.domain]
        ) ?? ""

        let isDisable = parseBoolKey(plistOut, key: "Disable")
        let isDisableMagicEdges = parseBoolKey(plistOut, key: "DisableMagicEdges")
        let isDisableAutoConnect = parseBoolKey(plistOut, key: "DisableAutoConnect")

        return UCState(
            universalControlEnabled: !isDisable,
            magicEdgesEnabled: !isDisableMagicEdges,
            autoReconnectEnabled: !isDisableAutoConnect
        )
    }

    private func parseBoolKey(_ plist: String, key: String) -> Bool {
        let pattern = "\\b\(key)\\s*=\\s*\"?1\"?\\b"
        return plist.range(of: pattern, options: .regularExpression) != nil
    }

    /// Enables or disables Universal Control, then restarts the daemon.
    func setUniversalControlEnabled(_ enabled: Bool) async throws {
        try await writeKey("Disable", enabled: enabled)
        try await restartDaemon()
    }

    /// Enables or disables "Push to connect" (Magic Edges), then restarts the daemon.
    func setMagicEdgesEnabled(_ enabled: Bool) async throws {
        try await writeKey("DisableMagicEdges", enabled: enabled)
        try await restartDaemon()
    }

    /// Enables or disables Auto-Reconnect, then restarts the daemon.
    func setAutoReconnectEnabled(_ enabled: Bool) async throws {
        try await writeKey("DisableAutoConnect", enabled: enabled)
        try await restartDaemon()
    }

    /// Kills the UniversalControl daemon immediately, severing all active connections
    /// without changing any preferences.
    func severAllConnections() async throws {
        try await restartDaemon()
    }

    // MARK: - Private Helpers

    /// Writes a "Disable*" key. Because all keys are inverted, `enabled = true` writes NO.
    private func writeKey(_ key: String, enabled: Bool) async throws {
        let result = try await shell.run(
            executable: "/usr/bin/defaults",
            arguments: ["write", Self.domain, key, "-bool", enabled ? "NO" : "YES"]
        )
        if result == nil {
            throw ShellError.writeFailed(domain: Self.domain, key: key)
        }
    }

    /// Kills the UniversalControl daemon. A non-zero exit (process not running) is fine.
    private func restartDaemon() async throws {
        // shell.run returns nil on non-zero exit; that's acceptable for pkill.
        _ = try await shell.run(
            executable: "/usr/bin/pkill",
            arguments: ["UniversalControl"]
        )
    }
}

// MARK: - Errors

enum ShellError: Error, LocalizedError {
    case writeFailed(domain: String, key: String)
    
    var errorDescription: String? {
        switch self {
        case .writeFailed(let domain, let key):
            return "Failed to write system preference '\(key)' in domain '\(domain)'. Ensure EdgeGuard has appropriate permissions."
        }
    }
}
