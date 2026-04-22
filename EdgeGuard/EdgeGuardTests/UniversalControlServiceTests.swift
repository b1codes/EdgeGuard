import Testing
@testable import EdgeGuard

// MARK: - Mock Shell Executor

/// A test double for ShellExecutor. Captures every command issued and returns
/// pre-configured output so tests never spawn real processes.
actor MockShellExecutor: ShellExecutor {
    private var stubbedOutput: [String: String] = [:]
    private(set) var capturedCommands: [(executable: String, arguments: [String])] = []

    /// Registers a canned response for a specific executable + arguments combination.
    func stub(executable: String, arguments: [String], output: String) {
        stubbedOutput[key(executable, arguments)] = output
    }

    func run(executable: String, arguments: [String]) async throws -> String? {
        capturedCommands.append((executable: executable, arguments: arguments))
        return stubbedOutput[key(executable, arguments)]
    }

    private func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }

    // MARK: - Assertion Helpers

    func hasDefaultsWrite(domainKey: String, value: String) -> Bool {
        capturedCommands.contains {
            $0.executable == "/usr/bin/defaults"
            && $0.arguments == ["write", "com.apple.universalcontrol", domainKey, "-bool", value]
        }
    }

    func hasPkill() -> Bool {
        capturedCommands.contains {
            $0.executable == "/usr/bin/pkill" && $0.arguments == ["UniversalControl"]
        }
    }

    func hasAnyDefaultsWrite() -> Bool {
        capturedCommands.contains {
            $0.executable == "/usr/bin/defaults" && $0.arguments.first == "write"
        }
    }
}

// MARK: - UniversalControlService Tests

// @MainActor is required because UCState's stored properties are implicitly @MainActor-isolated
// due to SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor in the main target.
@MainActor
@Suite("UniversalControlService")
struct UniversalControlServiceTests {

    // MARK: fetchState

    @Test("fetchState: all keys absent → all features enabled (default macOS state)")
    func fetchStateAllAbsent() async throws {
        let shell = MockShellExecutor()
        // No stubs → all shell.run calls return nil (key not found)
        let service = UniversalControlService(shell: shell)

        let state = try await service.fetchState()

        #expect(state.universalControlEnabled == true)
        #expect(state.magicEdgesEnabled == true)
        #expect(state.autoReconnectEnabled == true)
    }

    @Test("fetchState: Disable=1 → universalControlEnabled=false, others unaffected")
    func fetchStateUCDisabled() async throws {
        let shell = MockShellExecutor()
        await shell.stub(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.universalcontrol", "Disable"],
            output: "1"
        )
        let service = UniversalControlService(shell: shell)

        let state = try await service.fetchState()

        #expect(state.universalControlEnabled == false)
        #expect(state.magicEdgesEnabled == true)
        #expect(state.autoReconnectEnabled == true)
    }

    @Test("fetchState: DisableMagicEdges=1 → magicEdgesEnabled=false")
    func fetchStateMagicEdgesDisabled() async throws {
        let shell = MockShellExecutor()
        await shell.stub(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.universalcontrol", "DisableMagicEdges"],
            output: "1"
        )
        let service = UniversalControlService(shell: shell)

        let state = try await service.fetchState()

        #expect(state.universalControlEnabled == true)
        #expect(state.magicEdgesEnabled == false)
        #expect(state.autoReconnectEnabled == true)
    }

    @Test("fetchState: DisableAutoConnect=1 → autoReconnectEnabled=false")
    func fetchStateAutoReconnectDisabled() async throws {
        let shell = MockShellExecutor()
        await shell.stub(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.universalcontrol", "DisableAutoConnect"],
            output: "1"
        )
        let service = UniversalControlService(shell: shell)

        let state = try await service.fetchState()

        #expect(state.universalControlEnabled == true)
        #expect(state.magicEdgesEnabled == true)
        #expect(state.autoReconnectEnabled == false)
    }

    @Test("fetchState: Disable=0 (explicit false) → universalControlEnabled=true")
    func fetchStateExplicitFalse() async throws {
        let shell = MockShellExecutor()
        await shell.stub(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.universalcontrol", "Disable"],
            output: "0"
        )
        let service = UniversalControlService(shell: shell)

        let state = try await service.fetchState()

        // "0" means Disable=false, so UC is enabled
        #expect(state.universalControlEnabled == true)
    }

    // MARK: setUniversalControlEnabled

    @Test("setUniversalControlEnabled(false) → writes Disable=YES then pkill")
    func disableUC() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setUniversalControlEnabled(false)

        #expect(await shell.hasDefaultsWrite(domainKey: "Disable", value: "YES"))
        #expect(await shell.hasPkill())
    }

    @Test("setUniversalControlEnabled(true) → writes Disable=NO then pkill")
    func enableUC() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setUniversalControlEnabled(true)

        #expect(await shell.hasDefaultsWrite(domainKey: "Disable", value: "NO"))
        #expect(await shell.hasPkill())
    }

    // MARK: setMagicEdgesEnabled

    @Test("setMagicEdgesEnabled(false) → writes DisableMagicEdges=YES then pkill")
    func disableMagicEdges() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setMagicEdgesEnabled(false)

        #expect(await shell.hasDefaultsWrite(domainKey: "DisableMagicEdges", value: "YES"))
        #expect(await shell.hasPkill())
    }

    @Test("setMagicEdgesEnabled(true) → writes DisableMagicEdges=NO then pkill")
    func enableMagicEdges() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setMagicEdgesEnabled(true)

        #expect(await shell.hasDefaultsWrite(domainKey: "DisableMagicEdges", value: "NO"))
        #expect(await shell.hasPkill())
    }

    // MARK: setAutoReconnectEnabled

    @Test("setAutoReconnectEnabled(false) → writes DisableAutoConnect=YES then pkill")
    func disableAutoReconnect() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setAutoReconnectEnabled(false)

        #expect(await shell.hasDefaultsWrite(domainKey: "DisableAutoConnect", value: "YES"))
        #expect(await shell.hasPkill())
    }

    @Test("setAutoReconnectEnabled(true) → writes DisableAutoConnect=NO then pkill")
    func enableAutoReconnect() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.setAutoReconnectEnabled(true)

        #expect(await shell.hasDefaultsWrite(domainKey: "DisableAutoConnect", value: "NO"))
        #expect(await shell.hasPkill())
    }

    // MARK: severAllConnections

    @Test("severAllConnections() → only pkill, no defaults write")
    func severAllConnections() async throws {
        let shell = MockShellExecutor()
        let service = UniversalControlService(shell: shell)

        try await service.severAllConnections()

        #expect(await shell.hasPkill())
        #expect(await shell.hasAnyDefaultsWrite() == false)
    }
}
