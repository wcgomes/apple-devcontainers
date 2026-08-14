import Foundation
@testable import ADevContainerLib

// Keep progress + warning stderr off during the suite (noise + non-deterministic output).
// onWarning still fires for assertions; product QUIET only silences progress, not warnings.
StatusPrinter.enabled = false
StatusPrinter.suppressWarningStderr = true
StatusPrinter.resetSectionState()
// Default unit suite is monochrome unless a test explicitly enables color.
TerminalStyle.colorOverride = false

// Force-link test translation units by referencing their register functions.
let allTests: [(String, () throws -> Void)] = []
    + terminalStyleTests
    + statusPrinterTests
    + processRunnerFramingTests
    + cliErrorPresentationTests
    + interactivePickerTests
    + listCommandTests
    + discoveryTests
    + parserTests
    + substitutionTests
    + admissionTests
    + errorModelTests
    + remoteUserResolutionTests
    + runtimeTests
    + doctorTests
    + upTests
    + execTests
    + lifecycleTests
    + phase1Tests
    + phase2Tests
    + phase3Tests
    + phase4UnitTests
    + phase4CommandTests
    + featuresUnitTests
    + featuresCommandTests
    + cloneIdentityTests
    + gitClientTests
    + featureGitEnsureTests
    + cloneCommandTests
    + managedLifecycleTests
    + vscodeOpenURITests
    + vscodeOpenLauncherTests
    + vscodeOpenCommandTests
    + vscodePostAttachGateTests
    + vscodeCustomizationsParseTests
    + vscodeCustomizationsApplyTests
    + vscodeCustomizationsCommandTests
    + configReaderTests
    + rebuildCommandTests
    + rebuildPhaseTests
    + recoveryEditorTests
    + recoveryHelperTests
    + recoveryConfigSessionTests
    + recoveryOrchestratorTests
    + recoveryOutputTests
    + bringUpRecoveryTests
    + cloneRecoveryTests
    + startCommandRecoveryTests
    + upCommandRecoveryTests
    + integrationTests

// Optional PTY probes: run under a fresh controlling terminal so job-control
// claim/restore (and stdin delivery) can be verified without a developer TTY on the
// suite process itself. Invoked by PTY round-trip tests via `script`/`python` — not
// part of the normal suite entry.
if ProcessInfo.processInfo.environment["ADEVCONTAINER_TTY_RESTORE_PROBE"] == "1" {
    exit(InteractiveTTYRestoreProbe.run())
}
if ProcessInfo.processInfo.environment["ADEVCONTAINER_TTY_STDIN_PROBE"] == "1" {
    exit(InteractiveTTYRestoreProbe.runStdinRead())
}

let code = MiniTest.runAll(allTests)
exit(code)
