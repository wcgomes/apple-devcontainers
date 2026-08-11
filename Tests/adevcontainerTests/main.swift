import Foundation
@testable import ADevContainerLib

// Keep progress + warning stderr off during the suite (noise + non-deterministic output).
// onWarning still fires for assertions; product QUIET only silences progress, not warnings.
StatusPrinter.enabled = false
StatusPrinter.suppressWarningStderr = true

// Force-link test translation units by referencing their register functions.
let allTests: [(String, () throws -> Void)] = []
    + discoveryTests
    + parserTests
    + substitutionTests
    + admissionTests
    + errorModelTests
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
    + integrationTests

// Optional PTY restore probe: run under a fresh controlling terminal so job-control
// claim/restore can be verified without a developer TTY on the suite process itself.
// Invoked by the PTY round-trip test via `script`/`python` — not part of the normal suite.
if ProcessInfo.processInfo.environment["ADEVCONTAINER_TTY_RESTORE_PROBE"] == "1" {
    exit(InteractiveTTYRestoreProbe.run())
}

let code = MiniTest.runAll(allTests)
exit(code)
