import Foundation
import OilbirdCore
import OilbirdModel

// The whole of SonarQube's web API, reachable from both surfaces without a
// verb per endpoint and without a release of Oilbird per SonarQube release.

// ⚠ A hand-picked dozen endpoints is a guess, made in advance, about what an
// agent will want. `api/webservices/list` publishes the real
// contract, so the catalogue is complete and current by construction.

// The curated verbs stay: `scan`, `issues` and `gate` hold waits, read-backs
// and phrasing a generic caller cannot. Generic reach, curated ergonomics.
extension Oilbird {
    // ⚠ NOTHING under `api` is written down. A hand-written map of services
    // is wrong the day a version lands, and silently: a service that falls out
    // of it simply stops being listed.

    // The catalogue, groupings, descriptions and examples all come from the
    // running server. We cannot know which of 302 calls this instance
    // supports, so we say so once and let the server answer.

    /// An endpoint Oilbird performs itself, and will not perform on request.
    ///
    /// ⚠ Vanishingly small on purpose. This is not a safety rail around
    /// destructive calls — `projects/delete` and `issues/bulk_change` are
    /// destructive and both are allowed, because doing them is the point.
    /// It is single ownership of the engine: the two calls below are ones
    /// Oilbird makes as part of owning the engine, and a second party making
    /// them leaves Oilbird's model of the world wrong.
    public struct Reserved: Sendable, Equatable {
        public let path: String
        public let because: String
        public let instead: String

        public init(path: String, because: String, instead: String) {
            self.path = path
            self.because = because
            self.instead = instead
        }
    }

    public static let reserved: [Reserved] = [
        Reserved(
            path: "api/system/restart",
            because:
                "Oilbird supervises the engine — it holds the pid, the port and the idle "
                + "timer, and a restart underneath it leaves all three describing a process "
                + "that no longer exists.",
            instead: "oilbird down, then oilbird up"),
        Reserved(
            path: "api/system/migrate_db",
            because:
                "Oilbird runs the database upgrade itself on the first start after a version "
                + "bump, and waits it out before reporting the engine up. Driven from "
                + "outside, the wait is not taken and the first read lands mid-migration.",
            instead: "oilbird up, which migrates when it needs to"),
        Reserved(
            path: "api/users/change_password",
            because:
                "Oilbird authenticates as `admin` with a password it generated and stored. "
                + "Changing it locks Oilbird out of its own server — including the recovery "
                + "that re-mints a revoked analysis token, which is the thing that would "
                + "otherwise have healed it.",
            instead: "nothing: the password is Oilbird's, and no one else needs it"),
    ]

    /// Everything the running server says it can do.
    ///
    /// ⚠ Not cached. The catalogue changes on exactly one event — a SonarQube
    /// version bump — and that is precisely the moment a cache would serve
    /// the old contract. It is one request to a server on loopback that this
    /// call has already started.
    public static func apiCatalogue() async throws -> APICatalogue {
        let (running, token) = try await connected()
        return try await SonarAPI.catalogue(base: base(running.webPort), token: token)
    }

    /// Performs any endpoint, by path, with the parameters given.
    public static func apiCall(path: String, parameters: [String: String]) async throws -> String {
        let wanted = APICatalogue.normalise(path)
        if let held = reserved.first(where: { $0.path == wanted }) {
            throw OilbirdError(
                .verifyFailed,
                "\(held.path) is Oilbird's to call. \(held.because)",
                recovery: .chooseAlternative(held.instead),
                underlying: "reserved endpoint \(held.path)")
        }
        let (running, token) = try await connected()
        let catalogue = try await SonarAPI.catalogue(base: base(running.webPort), token: token)
        guard let endpoint = catalogue.endpoint(wanted) else {
            throw OilbirdError(
                .verifyFailed, unknownEndpoint(wanted, in: catalogue),
                recovery: .chooseAlternative("List the endpoints"),
                underlying: "no endpoint \(wanted) in \(catalogue.endpoints.count)")
        }
        // ⚠ Checked here only for ABSENCE: the server names a missing parameter
        // one at a time, so a call short of three takes three round trips. A
        // wrong VALUE it answers with the legal set.
        let missing = endpoint.required.map(\.key).filter { parameters[$0] == nil }
        if !missing.isEmpty {
            throw OilbirdError(
                .verifyFailed,
                "\(endpoint.path) needs \(counted(missing.count, "parameter")) it was not "
                    + "given: \(missing.joined(separator: ", ")).",
                recovery: .chooseAlternative("Describe the endpoint"),
                underlying: "missing required: \(missing.joined(separator: ","))")
        }
        let answer = try await SonarAPI.perform(
            base: base(running.webPort), token: token, endpoint: endpoint,
            parameters: parameters)
        await settle(endpoint, parameters)
        return answer.isEmpty ? "" : capped(answer)
    }

    /// Local state that a successful call has just invalidated.
    ///
    /// ⚠ **The generic caller can reach an endpoint a curated verb wraps, and
    /// the wrapper is not always only politeness.** `oilbird forget` deletes
    /// the project AND drops what Oilbird recorded about scanning it, with a
    /// comment saying why: a finished scan still listed for a project that no
    /// longer exists is a row whose every next step — `issues`, `gate`,
    /// `summary` — is a dead end. `api projects/delete` did the first half
    /// only, so opening the whole API up re-introduced exactly the dead end
    /// `forget` was written to close.
    ///
    /// ⚠ And the first fix for it named three endpoints —
    /// `projects/delete`, `projects/bulk_delete`, `projects/update_key` —
    /// which is a hand-maintained list of exactly the kind nothing else here
    /// has any more. SonarQube renames these between versions and the
    /// reconciliation would stop silently.
    ///
    /// So it asks a question instead of knowing an answer: after ANY write,
    /// does everything Oilbird remembers still exist? One request to a server
    /// on loopback, and it holds for endpoints nobody has written yet.
    static func settle(_ endpoint: APICatalogue.Endpoint, _ parameters: [String: String]) async {
        guard endpoint.post else { return }
        await reconcileProjects()
    }

    /// Drops what Oilbird recorded about a project it no longer has.
    static func forgetLocally(_ key: String) {
        guard !key.isEmpty else { return }
        Scans.forget(key: key)
        var stored = Preferences.load()
        if stored.projectNames?[key] != nil {
            stored.projectNames?[key] = nil
            try? Preferences.save(stored)
        }
    }

    /// Drops local records for projects the server no longer has.
    ///
    /// ⚠ Only for scans that FINISHED and succeeded. A scan that failed often
    /// failed before the project was ever created, so its record names a
    /// project the server has never heard of — and that record is the log of
    /// the failure, which is the one thing somebody needs. Reconciling on
    /// absence alone would delete exactly the evidence being looked for.
    static func reconcileProjects() async {
        guard let running = status(), let token = Secrets.load()?.analysisToken,
            let live = try? await SonarAPI.projects(base: base(running.webPort), token: token)
        else { return }
        let alive = Set(live.map(\.key))
        for entry in Scans.all()
        where !alive.contains(entry.key) && entry.state == .finished && entry.outcome != nil {
            if case .completed = entry.outcome { forgetLocally(entry.key) }
        }
    }

    /// A path that is not in the catalogue, said usefully.
    ///
    /// ⚠ "No such endpoint" is a dead end: the caller has a name that
    /// is nearly right and no way to find the right one. Nearly always it is
    /// a service that exists with an action that does not, so the actions of
    /// that service are worth more than an apology.
    public static func unknownEndpoint(_ wanted: String, in catalogue: APICatalogue) -> String {
        let service = wanted.split(separator: "/").dropLast().joined(separator: "/")
        let siblings = catalogue.endpoints.filter { $0.service == service }
        if !siblings.isEmpty {
            let names = siblings.map { $0.path.split(separator: "/").last.map(String.init) ?? "" }
            return "The server has no \(wanted). \(service) has: \(names.joined(separator: ", "))."
        }
        let word = wanted.split(separator: "/").last.map(String.init) ?? wanted
        let near = catalogue.endpoints.filter { $0.path.contains(word) }.prefix(6).map(\.path)
        if !near.isEmpty {
            return "The server has no \(wanted). Closest: \(near.joined(separator: ", "))."
        }
        return "The server has no \(wanted), and nothing resembling it."
    }

    /// ⚠ An agent pays for every byte of this in its context window, and
    /// `api/rules/search` answers 100 rules with their full descriptions —
    /// a quarter of a megabyte for a question that was probably about six of
    /// them. Truncated with the way to narrow it, rather than silently, and
    /// rather than not at all.
    static func capped(_ text: String, to limit: Int = 60_000) -> String {
        guard text.count > limit else { return text }
        let kept = String(text.prefix(limit))
        return kept + """


            … cut here: the answer is \(counted(text.count, "character")) and \
            \(counted(limit, "character")) is the most either surface will hand back. \
            Narrow it with the endpoint's own paging — `ps` for page size, `p` for the \
            page, `f` for which fields — rather than reading it in pieces.
            """
    }
}
