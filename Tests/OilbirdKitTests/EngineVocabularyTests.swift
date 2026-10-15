import Foundation
import OilbirdCore
import OilbirdKit
import OilbirdModel

/// Every state, so a new one cannot be added without deciding what it says.
private let everyState: [Oilbird.EngineState] = [
    .running(Oilbird.Running(webPort: 9000, databasePort: 9001)),
    .paused,
    .starting,
    .notInstalled,
    .unresponsive(Oilbird.Running(webPort: 9000, databasePort: 9001)),
]

func engineVocabularyTests() {
    Harness.suite("Engine vocabulary — four surfaces, one answer") {
        Harness.test("every state has a word and a heading") {
            for state in everyState {
                Harness.expectNotEmpty(state.word, "word for \(state)")
                Harness.expectNotEmpty(state.heading, "heading for \(state)")
            }
        }

        // The defect: the Engine menu enabled Resume while the engine was
        // running and Pause while it was paused, so pressing either did
        // nothing, while the pill's own menu got both right.
        Harness.test("pause is offered only where there is something to stop") {
            Harness.expectTrue(
                Oilbird.EngineState.running(Oilbird.Running(webPort: 1, databasePort: 2))
                    .canPause,
                "running")
            for state in [Oilbird.EngineState.paused, .starting, .notInstalled] {
                Harness.expectTrue(!state.canPause, "\(state) offered a pause")
            }
        }

        Harness.test("resume is offered only where the engine is not already up") {
            for state in [Oilbird.EngineState.paused, .notInstalled] {
                Harness.expectTrue(state.canResume, "\(state) offered no way forward")
            }
            Harness.expectTrue(
                Oilbird.EngineState.unresponsive(Oilbird.Running(webPort: 1, databasePort: 2))
                    .canResume,
                "a wedged engine offered no restart")
            Harness.expectTrue(
                !Oilbird.EngineState.running(Oilbird.Running(webPort: 1, databasePort: 2))
                    .canResume,
                "running offered a resume")
            // Starting is the one state where waiting is the whole answer:
            // a second start queues behind the first for no reason.
            Harness.expectTrue(!Oilbird.EngineState.starting.canResume, "starting")
        }

        // A control has to say what it does. "Resume" over an engine that
        // was never installed is a button that will not do what it claims.
        Harness.test("the way forward is labelled with the act it performs") {
            Harness.expectEqual(Oilbird.EngineState.paused.resumeLabel, "Resume")
            Harness.expectEqual(
                Oilbird.EngineState.unresponsive(Oilbird.Running(webPort: 1, databasePort: 2))
                    .resumeLabel,
                "Restart")
            Harness.expectTrue(
                Oilbird.EngineState.notInstalled.resumeLabel?.contains("Set up") == true,
                "a machine with nothing installed was offered a resume")
        }

        Harness.test("a label exists exactly when there is a way forward") {
            for state in everyState {
                Harness.expectEqual(
                    state.resumeLabel != nil, state.canResume, "disagreed for \(state)")
            }
        }

        // Nothing must be able to reach a state that offers neither action
        // and says nothing about why: that is a pill you can press with no
        // way out behind it.
        Harness.test("a state that offers nothing still says what it is") {
            for state in everyState where !state.canPause && !state.canResume {
                Harness.expectNotEmpty(state.heading, "silent dead end at \(state)")
            }
        }

        // The lock the state is derived from carries no reason across
        // processes, so no surface may name one. "Paused — nothing has
        // needed it" was false every time the user pressed Pause.
        Harness.test("paused does not invent a reason it cannot know") {
            let heading = Oilbird.EngineState.paused.heading.lowercased()
            Harness.expectTrue(!heading.contains("nothing"), heading)
            Harness.expectTrue(!heading.contains("needed"), heading)
        }

        Harness.test("running is the only state that reads as good") {
            for state in everyState {
                Harness.expectEqual(
                    state.tone == .good, state.isRunning, "tone disagreed for \(state)")
            }
        }
    }
}

func downloadDisclosureTests() {
    Harness.suite("First run — the size the user consents to") {
        // The window held four literals of its own. They are the manifest's
        // now, so a version bump cannot leave the disclosure describing the
        // previous release.
        Harness.test("every pinned entry carries the manifest's own size") {
            guard let manifest = try? Manifest.bundled(), let pinned = try? Oilbird.pinned()
            else {
                Harness.expectTrue(false, "the bundled manifest could not be read")
                return
            }
            Harness.expectEqual(pinned.count, DependencyID.allCases.count)
            for entry in pinned {
                guard let id = DependencyID(rawValue: entry.id),
                    let expected = try? manifest.entry(id)
                else {
                    Harness.expectTrue(false, "no manifest entry for \(entry.id)")
                    continue
                }
                Harness.expectEqual(entry.bytes, expected.bytes, "size for \(entry.id)")
                Harness.expectTrue(entry.bytes > 0, "\(entry.id) has no recorded size")
            }
        }

        Harness.test("the total is the sum of what will be fetched") {
            guard let manifest = try? Manifest.bundled(), let total = try? Oilbird.firstRunBytes()
            else {
                Harness.expectTrue(false, "the bundled manifest could not be read")
                return
            }
            let expected = DependencyID.allCases.reduce(Int64(0)) {
                $0 + ((try? manifest.entry($1))?.bytes ?? 0)
            }
            Harness.expectEqual(total, expected)
        }

        // ⚠ Dividing by 1024 twice and labelling the result "GB" discloses
        // 1,220,217,353 bytes as "1.14 GB", 7% short, in the one sentence
        // that must disclose the download before its first byte.
        Harness.test("the unit in the label is the unit in the arithmetic") {
            Harness.expectEqual(Oilbird.humanBytes(1_220_217_353), "1.22 GB")
            Harness.expectEqual(Oilbird.humanBytes(2_000_000_000), "2.00 GB")
            Harness.expectEqual(Oilbird.humanBytes(946_639_592), "947 MB")
        }

        Harness.test("no size is ever understated") {
            guard let total = try? Oilbird.firstRunBytes() else {
                Harness.expectTrue(false, "the bundled manifest could not be read")
                return
            }
            let said = Oilbird.humanBytes(total)
            guard let number = Double(said.split(separator: " ").first ?? "") else {
                Harness.expectTrue(false, "could not read a number out of \(said)")
                return
            }
            let claimed = said.hasSuffix("GB") ? number * 1_000_000_000 : number * 1_000_000
            // Within rounding of the real figure, and specifically not the
            // 1.14 GiB-labelled-GB that was there before.
            Harness.expectTrue(
                abs(claimed - Double(total)) / Double(total) < 0.005,
                "\(said) against \(total) bytes")
        }

        Harness.test("nothing to fetch reads as nothing, not as zero bytes") {
            Harness.expectEqual(Oilbird.humanBytes(0), "—")
            Harness.expectEqual(Oilbird.humanBytes(-1), "—")
        }
    }
}
