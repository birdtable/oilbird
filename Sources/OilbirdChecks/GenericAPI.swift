import Foundation

/// Nothing under `api` is written down, except the three calls Oilbird keeps.
///
/// The API surface is generated: the endpoints, their parameters, which are
/// required, the legal values, the examples, the service groupings and the
/// service descriptions all come off the running server's
/// `api/webservices/list`. There is no list of endpoints in the repo to go
/// stale, which is the point — SonarQube adds and renames these between
/// versions and we ship what it says.
///
/// Two things must still be held:
///
///   reserved  `Oilbird.reserved` names calls Oilbird makes as part of owning
///             the engine, which a second caller must not make. Three rows,
///             about OILBIRD's behaviour rather than SonarQube's taxonomy, so
///             they do not move with a version bump. But a reserved path the
///             server does not have is a row guarding nothing, and there the
///             zero IS the finding (DM-4) — it would sit in the source reading
///             like a rule while the call it names had been renamed out from
///             under it.
///
///   written   nothing else. An endpoint path spelled out in the API sources
///             is a hand-maintained list starting, and this catches the first
///             line of it rather than the fiftieth.
///
/// Read from the INSTALLED server, like `Overrides`. With no engine running
/// there is no catalogue, and this says so and passes rather than demanding
/// one on a clean machine.
struct GenericAPI: Check {
    let name = "api"
    let holds = "the generic API surface names no endpoint, and every reserved one exists"

    /// ⚠ Only the GENERIC surface. `SonarAPI.swift` spells out the endpoints
    /// the curated verbs call — `issues/search`, `qualitygates/project_status`
    /// — and those are hand-written on purpose: `oilbird issues` is not one
    /// call, it is a wait, a merge of two taxonomies and a page. This gate is
    /// about the surface that claims to be generated, and policing the other
    /// one would read as though every verb in the product were a mistake.
    private static let surface = "Sources/OilbirdKit/API.swift"

    private static let reservedBlock = Rx(
        "reserved: \\[Reserved\\] = \\[(.*?)\\n    \\]", [.dotMatchesLineSeparators])
    private static let reservedRow = Rx("Reserved\\(")
    private static let reservedPath = Rx("path:\\s*\"([^\"]+)\"")
    private static let endpoint = Rx("\"(api/[a-z_]+/[a-z_]+)\"")

    /// How the catalogue itself is fetched, and how a token is checked. Not
    /// endpoints Oilbird chose to call: endpoints it needs in order to have no
    /// list of endpoints at all.
    private static let plumbing = ["api/webservices/list", "api/authentication/validate"]

    func selfTest() throws {
        guard Self.endpoint.matches("let x = \"api/rules/create\"") else {
            throw SelfTest("a written-out endpoint path was not detected")
        }
        guard Self.reservedPath.matches("Reserved(path: \"api/system/health\")") else {
            throw SelfTest("a reserved row's path was not read")
        }
    }

    func run() throws -> Report {
        let kit = try Checkout.read(Self.surface) as NSString
        guard let block = Self.reservedBlock.first(in: kit), let body = block.group(1) else {
            throw Shape("Oilbird.reserved is gone, or has changed shape")
        }
        let rows = body as NSString
        let declared = Self.reservedRow.hits(in: rows).count
        let reserved = Self.reservedPath.capture(in: rows)
        guard reserved.count == declared else {
            throw Shape("\(declared) reserved row(s), \(reserved.count) could be read")
        }

        var report = Report(summary: "")
        let allowed = Set(reserved).union(Self.plumbing)
        var written: Set<String> = []
        for path in Self.endpoint.capture(in: kit) where !allowed.contains(path) {
            written.insert(path)
        }
        for spelled in written.sorted() {
            report.findings.append(
                "\(spelled) is spelled out in the source — the catalogue is generated, and "
                    + "one written path is a hand-maintained list starting")
        }

        guard let binary = Self.binary() else {
            report.summary =
                "\(reserved.count) reserved, \(written.count) written path(s) — no oilbird "
                + "binary, so the server's own catalogue was not read"
            report.skipped = true
            return report
        }

        // ⚠ The catalogue first. With no engine the binary still runs and
        // still exits non-zero, so an exit code alone cannot tell "no server"
        // from "the server dropped this call". A catalogue can.
        guard Self.ask(binary, ["api", "--json"]) != nil else {
            report.summary =
                "\(reserved.count) reserved, \(written.count) written path(s) — no engine "
                + "answered, so the server's own catalogue was not read"
            report.skipped = true
            return report
        }

        var checked = 0
        for path in reserved.sorted() {
            guard let service = Self.service(of: path) else {
                report.findings.append(
                    "'\(path)' is not shaped like an endpoint, so nothing can be asked about it")
                continue
            }
            guard let listing = Self.ask(binary, ["api", service, "--json"]),
                let endpoints = listing["endpoints"] as? [[String: Any]]
            else {
                report.findings.append(
                    "'\(path)' is reserved and this server has no `\(service)` service at all "
                        + "— the row guards nothing (DM-4)")
                continue
            }
            checked += 1
            let paths = Set(endpoints.compactMap { $0["path"] as? String })
            if !paths.contains(path) {
                report.findings.append(
                    "'\(path)' is reserved and the server does not have it — the row guards "
                        + "nothing (DM-4)")
            }
        }
        report.summary = "\(checked) reserved path(s) checked against the running server"
        return report
    }

    /// `api/system/restart` names the `system` service, which is the listing
    /// that can be asked whether the call exists.
    private static func service(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "api" else { return nil }
        return String(parts[1])
    }

    private static func binary() -> URL? {
        let candidates = [
            Checkout.url(".build/debug/oilbird"), URL(filePath: "/usr/local/bin/oilbird"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One `oilbird ... --json` call, decoded, or `nil` if it did not answer.
    ///
    /// ⚠ Through the CLI rather than by fetching the server directly. The
    /// catalogue needs a credential, and a check that reads `credentials.json`
    /// to verify a source file is a check holding a secret for no reason. The
    /// CLI already has the token and already answers this question; asking it
    /// also means the check exercises the surface it guards.
    ///
    /// A first attempt fetched the URL here and got `HTTP 401`, which the
    /// script reported as "could not reach the engine" and PASSED — checking
    /// nothing, quietly, which is the failure mode every check here is written
    /// against.
    private static func ask(_ binary: URL, _ arguments: [String]) -> [String: Any]? {
        let task = Process()
        task.executableURL = binary
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
