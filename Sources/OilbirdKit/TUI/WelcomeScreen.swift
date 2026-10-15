import SwiftTUI

/// Nothing is installed yet, and here is what that costs.
///
/// ⚠ Disclosure precedes the first byte. The sizes, the checksum
/// promise and "none of your code leaves this machine" are shown BEFORE
/// anything is fetched, not after.
public struct WelcomeScreen: View {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let size: String
        public let what: String

        public init(id: String, size: String, what: String) {
            self.id = id
            self.size = size
            self.what = what
        }
    }

    let items: [Item]
    let total: String

    public init(items: [Item], total: String) {
        self.items = items
        self.total = total
    }

    static let terms =
        ", once, resumable. Each is checked against a pinned SHA-256 before it is unpacked. "
        + "None of your code leaves this machine."

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Oilbird runs SonarQube privately on this Mac.").bold()
            Text("")
            Text(
                "Nothing is installed yet. Oilbird needs four things and will fetch them "
                    + "itself — you do not need Java, PostgreSQL or Docker."
            )
            Text("")
            AlignedTable(
                columns: [.init(heading: ""), .init(heading: ""), .init(heading: "")],
                rows: items.map {
                    [
                        .init(text: $0.id, role: Role.dim),
                        .init(text: $0.size, role: Role.dim),
                        .init(text: $0.what, role: Role.dim),
                    ]
                })
            Text("")
            // ⚠ The sentence is built first and interpolated once. A line
            // continuation INSIDE an interpolation does not parse, and the error it
            // gives points at the wrong thing entirely.
            Text("\(Text(total).bold())\(Text(Self.terms).foregroundStyle(Role.note))")
            Text("")
            Offers([
                .init(command: "oilbird up", what: "set it up now"),
                .init(command: "oilbird version", what: "see the list first"),
            ])
            Text("")
            Text("Already set up and seeing this? The container moved.")
                .foregroundStyle(Role.note)
            Offers([.init(command: "oilbird doctor", what: "says where it looked")])
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}

/// The engine is not running, and that is the product working.
public struct PausedScreen: View {
    let retrying: String
    let idle: String

    public init(retrying: String, idle: String) {
        self.retrying = retrying
        self.idle = idle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                "\(Text("paused").foregroundStyle(Role.attn)): the analysis engine is not running"
            )
            Text("")
            Text("Oilbird stops it \(idle) and gives back about 1.6 GB.")
            Text("Your results are all still here — reading them needs it running again.")
            Text("")
            Offers([
                .init(command: "oilbird up && \(retrying)", what: "start it and ask again"),
                .init(command: "oilbird idle never", what: "or stop it stopping"),
            ])
            Text("")
            Text(
                "exit 1. oilbird status answers without starting anything, and so do doctor "
                    + "and version."
            )
            .foregroundStyle(Role.note)
        }
        .padding(.init(horizontal: 2, vertical: 0))
    }
}
