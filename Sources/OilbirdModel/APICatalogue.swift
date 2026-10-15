import Foundation

/// SonarQube's whole web API, as the server describes it.
///
/// ⚠ Read from `api/webservices/list` and never written down here.
/// The server publishes 126 write endpoints across 26 services. A verb for
/// the dozen that seem worth having is a guess about what an agent will
/// want, made by someone who is not that agent, and
/// it goes stale on the next version bump — which for a pinned server is a
/// thing Oilbird does TO the user rather than something they choose.
///
/// The server already publishes its own contract: every path, every
/// parameter, which are required, what values they take, and whether the call
/// is a POST. So the catalogue is that document, parsed. A SonarQube that
/// gains an endpoint gains it here on the next start, with no release of
/// Oilbird at all.
public struct APICatalogue: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public let key: String
        public let description: String
        public let required: Bool
        public let possibleValues: [String]
        public let defaultValue: String?
        public let example: String?

        public init(
            key: String, description: String, required: Bool, possibleValues: [String],
            defaultValue: String?, example: String?
        ) {
            self.key = key
            self.description = description
            self.required = required
            self.possibleValues = possibleValues
            self.defaultValue = defaultValue
            self.example = example
        }
    }

    public struct Endpoint: Sendable, Equatable {
        /// The full path, `api/rules/create` — what a caller names it by.
        public let path: String
        public let summary: String
        /// POST endpoints change something. This is what decides how the
        /// call is sent, so it is taken from the server rather than guessed
        /// from the verb's name.
        public let post: Bool
        /// Marked internal by SonarSource: undocumented and free to change
        /// between versions. Reachable, but never listed without saying so.
        public let unsupported: Bool
        public let since: String?
        public let parameters: [Parameter]

        public init(
            path: String, summary: String, post: Bool, unsupported: Bool, since: String?,
            parameters: [Parameter]
        ) {
            self.path = path
            self.summary = summary
            self.post = post
            self.unsupported = unsupported
            self.since = since
            self.parameters = parameters
        }

        /// `api/rules/create` → `api/rules`.
        public var service: String {
            path.split(separator: "/").dropLast().joined(separator: "/")
        }

        public var required: [Parameter] { parameters.filter(\.required) }
    }

    public let endpoints: [Endpoint]
    /// What the server calls each service, in the server's own words.
    ///
    /// ⚠ Carried rather than written down here. An earlier draft grouped the
    /// 48 services into seven hand-picked "areas" with hand-written blurbs,
    /// which read better and was a list to maintain for ever: SonarQube adds
    /// and renames services between versions, and a map written against 26.9
    /// is wrong about 27 the day it ships. The server already describes its
    /// own services. We ship what SonarQube says and nothing else.
    public let descriptions: [String: String]

    /// ⚠ Two initialisers rather than one with a default. A defaulted
    /// parameter changes the mangled symbol, and `swift build` does not
    /// reliably rebuild the other targets against it — the link fails, or
    /// worse, does not. This codebase has been bitten by it three times.
    public init(endpoints: [Endpoint], descriptions: [String: String]) {
        self.endpoints = endpoints
        self.descriptions = descriptions
    }

    public init(endpoints: [Endpoint]) {
        self.init(endpoints: endpoints, descriptions: [:])
    }

    public func endpoint(_ path: String) -> Endpoint? {
        let wanted = APICatalogue.normalise(path)
        return endpoints.first { $0.path == wanted }
    }

    /// Accepts `rules/create`, `/api/rules/create` and `api/rules/create`.
    ///
    /// ⚠ An agent reading SonarQube's own documentation sees `api/rules/create`;
    /// one reading a URL sees `/api/rules/create`. Refusing either spelling
    /// teaches nothing and costs a round trip.
    public static func normalise(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.hasPrefix("api/") ? trimmed : "api/" + trimmed
    }

    /// Endpoints whose path or summary matches every word given.
    public func matching(_ query: String) -> [Endpoint] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return endpoints }
        return endpoints.filter { endpoint in
            let haystack = (endpoint.path + " " + endpoint.summary).lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    public struct Service: Sendable, Equatable {
        public let name: String
        public let about: String
        public let endpoints: Int
        public let writes: Int
        /// `api/project_branches` → `project_branches`.
        public var short: String {
            name.hasPrefix("api/") ? String(name.dropFirst(4)) : name
        }
    }

    /// The services, as the server groups them.
    public var services: [Service] {
        Dictionary(grouping: endpoints, by: \.service)
            .map {
                Service(
                    name: $0.key, about: descriptions[$0.key] ?? "",
                    endpoints: $0.value.count, writes: $0.value.filter(\.post).count)
            }
            .sorted { $0.name < $1.name }
    }
}
