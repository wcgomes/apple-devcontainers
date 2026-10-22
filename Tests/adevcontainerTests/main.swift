import Foundation
@testable import ADevContainerLib

// Private isolated probes for the detached broker suite. Dispatch before
// constructing or running the normal suite; the probe never uses product entry
// routing, Apple runtime ports, or the production broker context.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "__adevcontainer_git_broker" {
    exit(GitCredentialDetachedProbe.run(CommandLine.arguments[2]))
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "__adevcontainer_git_activate" {
    exit(GitCredentialDetachedProbe.activate(CommandLine.arguments[2], id: CommandLine.arguments[3] == "-" ? nil : CommandLine.arguments[3]))
}
// Keep progress + warning stderr off during the suite (noise + non-deterministic output).
// onWarning still fires for assertions; product QUIET only silences progress, not warnings.
StatusPrinter.enabled = false
StatusPrinter.suppressWarningStderr = true
StatusPrinter.resetSectionState()
// Default unit suite is monochrome unless a test explicitly enables color.
TerminalStyle.colorOverride = false

// Force-link test translation units by referencing their register functions.
let credentialTests = gitCredentialBrokerPolicyTests + gitCredentialProtocolTests + guestGitCredentialArtifactTests + credentialDuplexProcessTests + automaticHostGitCredentialTests + gitCredentialRuntimeTests + gitCredentialBrokerServiceTests + gitCredentialRelayChannelTests + gitCredentialBrokerEntryTests + gitCredentialConnectionTests + credentialProviderCrashTests + automaticGitCredentialsCommandTests + gitCredentialBrokerSmokeTests + gitCredentialBrokerDetachedTests
let allTests: [(String, () throws -> Void)] = credentialTests
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
    + supportInitSecurityOptTests
    + compatibilityContractTests
    + compatibilityPolicyTests
    + compatibilityCapAddTests
    + compatibilityStrictModeTests
    + errorModelTests
    + remoteUserResolutionTests
    + runtimeTests
    + appleStaleExecTests
    + doctorTests
    + containerPluginTests
    + upTests
    + credentialRefreshCommandTests
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
    + gitCredentialDiscoveryTests
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
if ProcessInfo.processInfo.environment["ADEVCONTAINER_PROVIDER_CRASH_PROBE"] == "1" {
    exit(CredentialProviderCrashProbe.run())
}
if ProcessInfo.processInfo.environment["ADEVCONTAINER_CREDENTIAL_SMOKE"] == "1" {
    let reason = GitCredentialBrokerSmokeHarness.liveRefusedReason() ?? "Live credential smoke was not executed."
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}

let legacyCredentialTests = gitClientTests.filter { ["hostGitCredentialFillParsesOutput", "hostGitCredentialTokenEnvEscapeHatch", "hostGitCredentialFillFailureReturnsNil", "parseCredentialOutputKeys"].contains($0.0) }
let automaticCloneTests = cloneCommandTests.filter { ["cloneHTTPSNonAzureUsesAutomaticConnectionBeforePopulate", "cloneHTTPSAzureUsesURLScopedHelper", "cloneHappyPathVolumeMountLabelsInContainerCloneJSON", "cloneHTTPSPublicWorksWithoutHostCredentials", "cloneHTTPSCloneFailWithoutCredsHintsCredentials", "cloneSSHInjectsCreateSSHFlag", "cloneLegacyHTTPPreservesDiscoveredScheme", "cloneReuseVolumePromptYesKeepsTree", "cloneGlobalAuthorFailureWarnsAndRunsHook", "cloneLocalAuthorFailureSkipsGlobalAndRunsHook"].contains($0.0) }
let automaticRebuildTests = rebuildPhaseTests.filter { ["rebuildBindSeedsFromHostRemotesBeforeHooks", "rebuildVolumeSeedsFromStampedGitURLWithoutEnumeration", "rebuildVolumeMissingGitURLSkipsSilently", "rebuildSeedingFailureWarnsAndContinues", "rebuildNeverSeedsOldContainerBeforeDelete", "rebuildBindIdentityOrderAndConnectionUser", "rebuildVolumeIdentityReadsGuestBeforeDelete", "rebuildGlobalIdentityFailureWarnsAndContinues", "rebuildVolumeGlobalFailurePreservesWorkspaceAndHook"].contains($0.0) }
let automaticLifecycleTests = upTests.filter { $0.0.hasPrefix("upFreshCreate") || $0.0.hasPrefix("upReuseRunning") || $0.0.hasPrefix("upStartStopped") } + credentialRefreshCommandTests + gitCredentialDiscoveryTests + automaticRebuildTests + vscodeOpenCommandTests.filter { $0.0 == "realBindStartRunsInitializeCommandFromStampedHostPath" }
let selectedTests: [(String, () throws -> Void)]
if ProcessInfo.processInfo.environment["ADEVCONTAINER_CREDENTIAL_TESTS_ONLY"] == "1" {
    selectedTests = credentialTests + legacyCredentialTests + automaticCloneTests + automaticLifecycleTests
} else if ProcessInfo.processInfo.environment["ADEVCONTAINER_TESTS_SYNTHETIC_ONLY"] == "1" {
    // AllIntegrationTests contains runtime mutations/network checks behind its
    // availability probe. Exclude the group explicitly; never stop the runtime
    // or fake its availability to make destructive integration appear to pass.
    selectedTests = Array(allTests.dropLast(integrationTests.count))
    print("Excluded \(integrationTests.count) live integration tests (not executed; no target-runtime coverage claimed).")
} else { selectedTests = allTests }
let code = MiniTest.runAll(selectedTests)
exit(code)
