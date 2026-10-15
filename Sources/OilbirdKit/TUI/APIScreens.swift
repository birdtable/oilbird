import OilbirdModel
import SwiftTUI

/// The API, as the server groups it.
///
/// ⚠ Every word comes off `api/webservices/list`. Nothing here is written
/// down, so a SonarQube that adds a service shows it without a release of
/// Oilbird, and one that drops a service stops showing it without a stale row.
public struct APIServicesScreen: View {
    let catalogue: APICatalogue

    public init(catalogue: APICatalogue) {
        self.catalogue = catalogue
    }

    public var body: some View {
        let services = catalogue.services
        let writes = catalogue.endpoints.filter(\.post).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text("\(catalogue.endpoints.count) calls").bold()
                Text("across \(services.count) services, \(writes) of them writes")
                    .foregroundStyle(Role.note)
            }
            Text("")
            AlignedTable(
                columns: [
                    .init(heading: ""), .init(heading: "", trailing: true),
                    .init(heading: "", elastic: true),
                ],
                rows: services.map {
                    [
                        .init(text: $0.short),
                        .init(text: String($0.endpoints), role: Role.dim),
                        .init(text: $0.about, role: Role.dim),
                    ]
                })
            Text("")
            // ⚠ Said once, plainly. This is one machine, one user, Community Build:
            // a large share of these cannot do anything here, and Oilbird cannot
            // know which.
            Text(
                "This is what this server says it has. Not all of it can work here — one "
                    + "machine, one user, Community Build — and the ones that cannot will say "
                    + "so in their own words."
            )
            .foregroundStyle(Role.note)
            Text("")
            Offers([
                .init(command: "oilbird api rules", what: "one service"),
                .init(command: "oilbird api rules/create", what: "what one call takes"),
                .init(command: "oilbird api find custom rule", what: "search all of them"),
            ])
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}

/// A set of endpoints, grouped by the service they belong to.
public struct APIEndpointsScreen: View {
    let endpoints: [APICatalogue.Endpoint]
    let title: String
    let about: String

    public init(endpoints: [APICatalogue.Endpoint], title: String, about: String = "") {
        self.endpoints = endpoints
        self.title = title
        self.about = about
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if endpoints.isEmpty {
                HStack(spacing: 1) {
                    Text("none").foregroundStyle(Role.attn)
                    Text("nothing \(title).")
                }
                Text("")
                Offers([.init(command: "oilbird api", what: "the services")])
            } else {
                Text(title).bold()
                if !about.isEmpty {
                    Text(about).foregroundStyle(Role.note)
                }
                Text("")
                // Grouped, because a flat list of sixty paths is a wall and
                // the service is already in the path.
                let grouped = Dictionary(grouping: endpoints, by: \.service)
                    .sorted { $0.key < $1.key }
                ForEach(grouped, id: \.key) { service, group in
                    Text(service).foregroundStyle(Role.note)
                    AlignedTable(
                        columns: [
                            .init(heading: ""), .init(heading: ""),
                            .init(heading: "", elastic: true),
                        ],
                        rows: group.sorted { $0.path < $1.path }.map { endpoint in
                            [
                                .init(
                                    text: endpoint.path.replacingOccurrences(
                                        of: "api/", with: "")),
                                .init(
                                    text: endpoint.post ? "writes" : "reads",
                                    role: endpoint.post ? Role.warn : Role.dim),
                                .init(text: endpoint.summary, role: Role.dim),
                            ]
                        })
                    Text("")
                }
                Text(
                    "Any of them: oilbird api <call> to see what it takes, then add key=value "
                        + "to run it."
                )
                .foregroundStyle(Role.note)
            }
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}

/// One endpoint, as a thing you could call in the next line.
public struct APIEndpointScreen: View {
    let endpoint: APICatalogue.Endpoint

    public init(endpoint: APICatalogue.Endpoint) {
        self.endpoint = endpoint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(endpoint.path).bold()
                Text(endpoint.post ? "writes" : "reads")
                    .foregroundStyle(endpoint.post ? Role.attn : Role.note)
            }
            if !endpoint.summary.isEmpty {
                Text("")
                Text(endpoint.summary).foregroundStyle(Role.note)
            }
            if endpoint.unsupported {
                Text("")
                HStack(spacing: 1) {
                    Text("unsupported").foregroundStyle(Role.attn)
                    Text("SonarSource marks this one internal: undocumented, and free to change.")
                        .foregroundStyle(Role.note)
                }
            }
            Text("")
            if endpoint.parameters.isEmpty {
                Text("It takes no parameters.").foregroundStyle(Role.note)
            } else {
                AlignedTable(
                    columns: [
                        .init(heading: "parameter"), .init(heading: ""),
                        .init(heading: "", elastic: true),
                    ],
                    rows: endpoint.parameters.map { parameter in
                        var says = parameter.description
                        if !parameter.possibleValues.isEmpty {
                            let shown = parameter.possibleValues.prefix(8)
                            says =
                                "one of: " + shown.joined(separator: ", ")
                                + (parameter.possibleValues.count > 8 ? ", …" : "")
                        }
                        return [
                            .init(text: parameter.key),
                            .init(
                                text: parameter.required ? "required" : "optional",
                                role: parameter.required ? Role.warn : Role.dim),
                            .init(text: says, role: Role.dim),
                        ]
                    })
            }
            Text("")
            Text("Call it:").foregroundStyle(Role.note)
            Offers([.init(command: Self.example(endpoint), what: "")])
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }

    /// A runnable line, built from the endpoint's own required parameters.
    ///
    /// ⚠ Falls back to the parameter's description in angle brackets rather
    /// than an ellipsis. 74 of the server's required parameters carry no
    /// example, and `customKey=…` is not something anyone can run.
    nonisolated public static func example(_ endpoint: APICatalogue.Endpoint) -> String {
        let short = endpoint.path.replacingOccurrences(of: "api/", with: "")
        let pairs = endpoint.required.map { parameter -> String in
            let value =
                parameter.example ?? parameter.possibleValues.first
                ?? "<\(parameter.description.isEmpty ? parameter.key : parameter.description)>"
            return "\(parameter.key)=\(value)"
        }
        return (["oilbird api", short] + pairs).joined(separator: " ")
    }
}
