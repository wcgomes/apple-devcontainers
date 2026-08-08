import Foundation
@testable import ADevContainerLib

// Keep phase status off during the suite (stderr noise + non-deterministic output).
StatusPrinter.enabled = false

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
    + integrationTests

let code = MiniTest.runAll(allTests)
exit(code)
