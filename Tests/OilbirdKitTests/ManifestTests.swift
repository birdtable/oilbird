import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

func manifestTests() {
    Harness.suite("Manifest — one home for every version string") {
        Harness.test("the bundled manifest loads and names all four dependencies") {
            guard let manifest = try? Manifest.bundled() else {
                Harness.expectTrue(false, "bundled manifest did not load")
                return
            }
            Harness.expectEqual(manifest.schema, Manifest.supportedSchema)
            for dependency in DependencyID.allCases {
                let entry = try? manifest.entry(dependency)
                Harness.expectTrue(entry != nil, "no entry for \(dependency)")
            }
        }

        Harness.test("every entry carries both a size and a digest") {
            guard let manifest = try? Manifest.bundled() else { return }
            for dependency in DependencyID.allCases {
                guard let entry = try? manifest.entry(dependency) else { continue }
                Harness.expectTrue(entry.bytes > 0, "\(dependency) has no size")
                Harness.expectEqual(entry.sha256.count, 64, "\(dependency) digest is not SHA-256")
                Harness.expectNotEmpty(entry.licence, "\(dependency) has no licence")
            }
        }

        // verify is a KIND, never a command: each names a workload rather than
        // a version flag. This is the rule the JRE mistake produced.
        Harness.test("the JDK verifies by booting the server, not by java -version") {
            guard let manifest = try? Manifest.bundled(),
                let jdk = try? manifest.entry(.jdk)
            else { return }
            Harness.expectEqual(jdk.verify, .serverUp)
        }

        Harness.test("the postgres artifact is declared as the two-stage jar+txz") {
            guard let manifest = try? Manifest.bundled(),
                let postgres = try? manifest.entry(.postgres)
            else { return }
            Harness.expectEqual(postgres.archive, .jarTxz)
        }

        Harness.test("a manifest from an unknown schema is refused, not guessed at") {
            let future = Data(#"{"schema":99,"dependencies":{}}"#.utf8)
            var refused = false
            do { _ = try Manifest.load(from: future) } catch { refused = true }
            Harness.expectTrue(refused, "a future schema was accepted")
        }

        Harness.test("an unreadable manifest fails with a recovery, not a crash") {
            var recovery: OilbirdError.Recovery?
            do { _ = try Manifest.load(from: Data("not json".utf8)) } catch let error as OilbirdError {
                recovery = error.recovery
            } catch {}
            Harness.expectTrue(recovery != nil, "no OilbirdError was thrown")
            Harness.expectNotEmpty(recovery?.actionLabel ?? "", "recovery had no action")
        }
    }
}

func pinnedVersionTests() {
    Harness.suite("Pinned — what this build says it runs") {
        // ⚠ The verb is worth having only if it is COMPLETE: reporting three of
        // four dependencies answers "which versions am I on?" while missing
        // the one being asked about.
        Harness.test("every dependency is named") {
            let pins = (try? Oilbird.pinned()) ?? []
            Harness.expectEqual(
                pins.map(\.id).sorted(), DependencyID.allCases.map(\.rawValue).sorted(),
                "one Pinned per DependencyID")
        }
        Harness.test("no version or licence is blank") {
            for pin in (try? Oilbird.pinned()) ?? [] {
                Harness.expectNotEmpty(pin.version, "version for \(pin.id)")
                Harness.expectNotEmpty(pin.licence, "licence for \(pin.id)")
            }
        }
        // Running from `.build` there is no Info.plist to stamp, and a
        // fabricated commit in a bug report is worse than an absent one.
        Harness.test("the build stamp is absent rather than invented") {
            Harness.expectNil(Oilbird.build.commit, "commit outside a bundle")
            Harness.expectNotEmpty(Oilbird.build.version, "version")
        }
    }
}
