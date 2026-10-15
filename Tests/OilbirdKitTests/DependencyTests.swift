import Foundation
import OilbirdModel

func dependencyTests() {
    Harness.suite("Dependencies") {
        Harness.test("the four managed dependencies are the four in the map") {
            Harness.expectEqual(DependencyID.allCases.count, 4)
            Harness.expectTrue(DependencyID.allCases.contains(.sonarqube))
            Harness.expectTrue(DependencyID.allCases.contains(.jdk))
            Harness.expectTrue(DependencyID.allCases.contains(.postgres))
            Harness.expectTrue(DependencyID.allCases.contains(.scanner))
        }

        Harness.test("health distinguishes missing from corrupt from present") {
            Harness.expectTrue(DependencyHealth.missing != .present(version: "26.9.0"))
            Harness.expectTrue(
                DependencyHealth.corrupt(reason: "checksum") != .present(version: "26.9.0"))
            Harness.expectEqual(
                DependencyHealth.present(version: "26.9.0"), .present(version: "26.9.0"))
        }
    }
}
