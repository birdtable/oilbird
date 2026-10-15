import Foundation

/// Help with a mistyped verb.
enum Usage {
    /// Every verb the switch accepts. ⚠ Held level by the `parity` check,
    /// which reads the same `case "verb":` lines — a verb added to one and
    /// not the other is the kind of drift this list would otherwise start.
    static let verbs = [
        "doctor", "install", "up", "down", "status", "scan", "scans", "follow",
        "issues", "gate", "summary", "history", "projects", "version", "cli-install",
        "cli-uninstall", "idle", "watch", "log", "forget", "configure", "api",
    ]

    /// The verbs that read from the engine, and therefore start one.
    ///
    /// ⚠ This IS the "LOOK AT CODE" section of `--help`, and `UITests` holds
    /// the two level. The screen made a promise about a group of verbs and
    /// the group existed only in prose: it said "the first six" over a
    /// section of seven, having been written when it was two.
    ///
    /// `scan` starts one inside `Oilbird.scan`, and everything else here
    /// through `Oilbird.connected` — this set exists so the wait is DRAWN,
    /// not so the start happens.
    static let needEngine: Set<String> = [
        "scan", "issues", "gate", "summary", "history", "projects", "forget", "api",
    ]

    /// The ones whose start can be drawn before the switch dispatches.
    ///
    /// ⚠ `scan` is the exception and draws its own from inside its case,
    /// because doing it here broke two things the moment it was tried.
    /// `scan` validates its path first — starting a 1.6 GB engine and then
    /// answering "there is nothing at /tpm/thing" is fifteen seconds spent on
    /// a typo — and `scan --detach` hands the work to a child that starts its
    /// own engine, so a start here would block the hand-off it exists to
    /// avoid and would mask the "already being scanned" refusal behind
    /// whatever the engine had to say.
    static let startsBeforeDispatch = needEngine.subtracting(["scan"])

    /// The closest verb within a small edit distance, or nil.
    ///
    /// Bounded at two edits and at half the word: without the second bound
    /// every three-letter typo matches something, and a confident wrong
    /// suggestion is worse than none.
    static func nearestVerb(to typed: String) -> String? {
        let budget = min(2, max(1, typed.count / 2))
        return
            verbs
            .map { ($0, distance(from: typed.lowercased(), to: $0)) }
            .filter { $0.1 <= budget }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Levenshtein, two rows rather than a matrix. The words are verbs.
    static func distance(from source: String, to target: String) -> Int {
        let a = Array(source), b = Array(target)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}
