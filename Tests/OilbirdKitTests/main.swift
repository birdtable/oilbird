import Foundation
import OilbirdCore

// Hermetic by construction: every suite runs against a throwaway container.

// ⚠ Relocating HOME does NOT achieve this: `homeDirectoryForCurrentUser` reads
// `getpwuid` and ignores the environment, so the suites write into the
// developer's real container and one run changes the next one's count.
let sandbox = URL(filePath: NSTemporaryDirectory())
    .appending(path: "oilbird-tests-\(UUID().uuidString)")
setenv(Paths.containerRootVariable, sandbox.path, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

// The harness has no discovery: a suite that is not called here silently never
// runs. Registering it here is part of adding it.

Harness.selfTest()

oilbirdErrorTests()
dependencyTests()
pathsTests()
manifestTests()
pinnedVersionTests()
resolverTests()
portsTests()
ownerTests()
childTests()
streamingTests()
managedDependencyTests()
fetchFaultTests()
faultTests()
dependencyRegistrationTests()
extractionTests()
commandLineToolTests()
tintTests()
bundleLayoutTests()
preferencesTests()
clusterTests()
readinessTests()
sonarQubeTests()
superviseTests()
sonarAPITests()
migrationTests()
tokenRecoveryTests()
screenFrameTests()
summaryScreenTests()
gateScreenTests()
historyScreenTests()
scansScreenTests()
diagnosisRowTests()
statusScreenTests()
browserTests()
browserJourneyTests()
versionPinTests()
installedManifestTests()
clusterCompatibilityTests()
configurationTests()
secretsTests()
provisioningTests()
projectTests()
scanDegradationTests()
scanVersionTests()
projectKeyTests()
analysedNothingTests()
refusalMessageTests()
scannerTests()
diagnosisTests()
logTests()
idleTests()
// After `idleTests`, which asserts that nothing is attached when it
// begins: this suite runs a real detached scan and a real watchdog, and
// leaving that overlapping the attachment suite would make both flaky.
scansTests()
cliContractTests()
engineVocabularyTests()
downloadDisclosureTests()
// The preference suite writes the container's preferences file, so
// it runs after everything that reads one — `preferencesTests` and
// `idleTests` both assume the defaults.
settingsPreferenceTests()
// An appearance to choose, and one preference
// deciding what closing the last window does. Both write the preferences
// file, so they belong in this block for the reason above.
appearancePreferenceTests()
residencyTests()
commandLineBinaryTests()
storageTests()
agentAccessTests()
settingsFactTests()
detectedVersionTests()
installLocationTests()
// A settings window that showed a long home directory in full in four
// places.
displayPathTests()
// The terminal design system: what survives a pipe, what only exists
// at a known terminal, and the measurement that tells them apart.
uiTests()
browseTests()

Harness.finish()
