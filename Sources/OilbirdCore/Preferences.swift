import Foundation

/// The user's own choices.
///
/// A plist under the config root rather than `UserDefaults`, so it follows
/// `OILBIRD_HOME` like everything else — a preference that ignored the
/// container override would leak a developer's real settings into every
/// sandboxed test run.
public enum Preferences {
    /// When the server stops if nothing is using it.
    ///
    /// A setting rather than a fixed decision, because every candidate answer
    /// is the same mechanism with a different constant, and the right answer
    /// genuinely differs by machine: a laptop with 16 GB wants it to stop, a
    /// desktop running agents all day wants it warm.
    ///
    /// The measurement that settles the default: SonarQube rests at about
    /// 490 MB natively, and a warm restart is roughly 24 seconds. So neither
    /// answer is painful, and the polite one wins by default.
    /// How long the engine may sit unused before it is stopped.
    ///
    /// Any number of minutes, not a few fixed choices: forty-five minutes is
    /// a perfectly ordinary thing to want.
    ///
    /// It encodes as the same strings the earlier enum used — `30m`, `2h`, `never` —
    /// so a preferences file written by an older build decodes unchanged and
    /// stays readable with `cat`.
    public enum IdleTimeout: Sendable, Codable, Equatable {
        case after(minutes: Int)
        /// Runs until told otherwise. Never at login — nothing Oilbird
        /// installs starts on its own.
        case never

        /// The shortest interval that is not self-defeating.
        ///
        /// A warm start measured about fifteen seconds. Below five minutes
        /// the engine stops between a person's own clicks while they read a
        /// dashboard, and they pay that wait again to carry on — so a
        /// shorter value costs more time than it saves. Anything below is
        /// refused rather than silently rounded, because silently doing
        /// something other than what was asked is worse than saying no.
        public static let floorMinutes = 5

        public static let thirtyMinutes = IdleTimeout.after(minutes: 30)
        public static let twoHours = IdleTimeout.after(minutes: 120)

        /// The common choices, for a UI that offers some.
        public static var presets: [IdleTimeout] { [thirtyMinutes, twoHours, .never] }

        public var seconds: TimeInterval? {
            switch self {
            case .after(let minutes): TimeInterval(minutes) * 60
            case .never: nil
            }
        }

        public var rawValue: String {
            switch self {
            case .after(let minutes):
                minutes.isMultiple(of: 60) ? "\(minutes / 60)h" : "\(minutes)m"
            case .never: "never"
            }
        }

        public var label: String {
            switch self {
            case .after(let minutes) where minutes.isMultiple(of: 60):
                "After \(minutes / 60) hour\(minutes == 60 ? "" : "s") idle"
            case .after(let minutes): "After \(minutes) minutes idle"
            case .never: "Never — leave it running"
            }
        }

        /// The same policy as one line in a menu.
        ///
        /// ⚠ The menu used to interpolate `rawValue` into "Stops after
        /// \(…)", which reads "Stops after never" for the one setting that
        /// means it never stops — ungrammatical in exactly the case a
        /// person is most likely to be checking. The whole sentence is
        /// chosen per case rather than a word dropped into a fixed frame.
        public var menuSentence: String {
            switch self {
            case .after: "Stops after \(rawValue) unused"
            case .never: "Never stops on its own"
            }
        }

        /// Parses what a person types: `45`, `45m`, `2h`, `never`.
        ///
        /// Returns nil for anything else, including a value below the floor
        /// — the caller says why, because "5 is the minimum" is a better
        /// message than "not a valid value".
        public init?(rawValue: String) {
            let text = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
            if text == "never" {
                self = .never
                return
            }
            let minutes: Int?
            if text.hasSuffix("h") {
                minutes = Int(text.dropLast()).map { $0 * 60 }
            } else if text.hasSuffix("m") {
                minutes = Int(text.dropLast())
            } else {
                minutes = Int(text)
            }
            guard let minutes, minutes >= Self.floorMinutes else { return nil }
            self = .after(minutes: minutes)
        }

        public init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            // A stored value below the floor is honoured: it was legal when
            // written, and refusing to decode leaves the user with a settings
            // file they cannot load. Only new input is held to it.
            if text == "never" {
                self = .never
            } else if text.hasSuffix("h"), let hours = Int(text.dropLast()) {
                self = .after(minutes: hours * 60)
            } else if text.hasSuffix("m"), let minutes = Int(text.dropLast()) {
                self = .after(minutes: minutes)
            } else if let minutes = Int(text) {
                self = .after(minutes: minutes)
            } else {
                self = Self.thirtyMinutes
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// The ports the engine used last time.
    ///
    /// Remembered so a restart lands where it landed before, which is what
    /// makes it invisible to a scanner already running against the old one.
    /// Stored here rather than in `running.json` because that
    /// file is deleted by the very stop these are meant to survive.
    ///
    /// Advisory, never authoritative: `Ports.preferring` checks each is
    /// still free and takes a fresh one if not, so a stale value costs
    /// nothing.
    public struct LastPorts: Sendable, Codable, Equatable {
        public var web: UInt16
        public var search: UInt16

        public init(web: UInt16, search: UInt16) {
            self.web = web
            self.search = search
        }
    }

    /// How much heap the analysis server's web process gets.
    ///
    /// SonarQube's own default is `-Xmx512m -Xms128m
    /// -XX:+HeapDumpOnOutOfMemoryError`, read out of `ProcessProperties` in
    /// the pinned jar rather than remembered — and 512 MB is where the web
    /// server was seen dying on a large report. Oilbird never wrote
    /// `sonar.web.javaOpts` at all, so that ceiling was not a decision
    /// anyone had made; it was the one nobody had.
    public enum WebMemory {
        /// What SonarQube uses when nothing says otherwise.
        public static let defaultMegabytes = 512

        /// The choices offered. Below the default is not offered: the
        /// failure this setting exists for is running out, and a smaller
        /// heap can only make it likelier.
        public static let choices = [512, 1024, 2048]

        /// The full option string for a heap size.
        ///
        /// ⚠ The rest of the default is reproduced, not dropped. Writing
        /// `sonar.web.javaOpts` REPLACES SonarQube's default wholesale, so
        /// setting only `-Xmx` would silently take away the heap dump the
        /// default asks for — which is the one artefact that makes the next
        /// OOM diagnosable.
        public static func javaOpts(megabytes: Int) -> String {
            "-Xmx\(megabytes)m -Xms128m -XX:+HeapDumpOnOutOfMemoryError"
        }
    }

    /// Which palette Oilbird wears — and, with it, the dashboard it frames.
    ///
    /// ⚠ **One control drives both surfaces, and that is the mechanism
    /// rather than a coincidence.** A window's `NSAppearance` reaches every
    /// view it owns, the `WKWebView` included, and the web view's
    /// `prefers-color-scheme` follows it. That is how `Theme.pinToPaper`
    /// silently forced SonarQube's own dashboard back into its light theme
    /// while nothing anywhere said so. Turned round and offered to the user
    /// it is a theme switch for the whole product: SonarQube's own script
    /// reads `prefers-color-scheme` and stamps `data-echoes-theme`, and
    /// `Tint` already writes a block for each of the two. No injection, no
    /// second setting inside the dashboard to keep in step.
    ///
    /// SonarQube itself offers System, Dark and Light, so a wrapper offering
    /// fewer would take away a choice the thing inside it already had.
    public enum Appearance: String, Sendable, Codable, CaseIterable {
        /// Whatever the Mac is set to, and what macOS asks an app to do
        /// unless the user says otherwise. The default.
        case auto
        case light
        case dark

        /// Offered in this order: the default first, then the two that
        /// override it, light before dark as System Settings has them.
        public static var choices: [Appearance] { allCases }

        public var label: String {
            switch self {
            case .auto: "Auto"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// Whether Oilbird pins anything at all.
        ///
        /// `auto` pins nothing, which is NOT the same as pinning whichever
        /// appearance the system happens to be wearing when it is read: the
        /// difference is what happens when the user changes their mind with
        /// Oilbird already open.
        public var followsSystem: Bool { self == .auto }
    }

    public struct Stored: Sendable, Codable {
        public var idleTimeout: IdleTimeout = .thirtyMinutes
        /// Optional so a preferences file written before this existed still
        /// decodes — a user upgrading mid-session must not be handed a
        /// broken settings file.
        public var lastPorts: LastPorts?

        /// Whether Oilbird puts a mark in the menu bar.
        ///
        /// Always on until this existed: a behaviour with no switch.
        public var menuBarIcon: Bool = true

        /// Whether closing the last window leaves Oilbird running.
        ///
        /// Unconditional until this existed. It is the right default and it
        /// is not everybody's: a person who wants a window and nothing else
        /// had no way to say so.
        public var stayResident: Bool = true

        /// What a project should be CALLED, by key.
        ///
        /// ⚠ Kept here rather than on the server, because SonarQube has
        /// nowhere to put it. Counted from `api/webservices/list` with
        /// internals included, `api/projects` offers `create`, `delete`,
        /// `bulk_delete`, `update_key` and `update_visibility` — and no
        /// rename. The only thing that sets a project's name is an
        /// ANALYSIS carrying `sonar.projectName`, so a name chosen here is
        /// a name applied at the next scan, and every surface that offers
        /// it has to say so rather than report a success that has not
        /// happened yet.
        ///
        /// Optional, so a preferences file written before this decodes.
        public var projectNames: [String: String]?

        /// Light, dark, or the system's choice. See `Appearance`.
        public var appearance: Appearance = .auto

        /// Heap for the analysis server's web process, or `nil` for
        /// SonarQube's own default. See `WebMemory`.
        public var webMemoryMegabytes: Int?

        /// A port the user has fixed, for anything that has hard-coded the
        /// dashboard URL.
        ///
        /// Advisory in exactly the way `lastPorts` is: `Ports.preferring`
        /// still checks it is free and takes a fresh one if not, because
        /// designing "port already in use" out of existence is the property
        /// `Ports` exists to keep. Pinning changes which port is *asked
        /// for*, not whether the engine starts.
        public var pinnedWebPort: UInt16?

        /// Globs never analysed. The whole list, not an addition to a
        /// hidden one.
        ///
        /// Not an addition to a hidden constant the user cannot remove.
        /// SonarQube itself does not force such a list: it ships
        /// `**/vendor/**` for Go, PHP and Ruby *only*, because `vendor/`
        /// means something in those languages and nothing in Java, and all
        /// 208 of its settings are values a user can change. One unremovable
        /// list for every language would be wrong in most of them.
        ///
        /// Seeded from `ScannerCommand.defaultNeverSource` on a first run
        /// and owned by the user thereafter. Empty is a legitimate answer.
        public var neverAnalysed: [String] = ScannerCommand.defaultNeverSource

        /// Globs scored as test code rather than production code. The whole
        /// list, seeded the same way.
        public var treatedAsTests: [String] = ScannerCommand.defaultTestPatterns

        public init(
            idleTimeout: IdleTimeout = .thirtyMinutes, lastPorts: LastPorts? = nil,
            menuBarIcon: Bool = true, stayResident: Bool = true,
            appearance: Appearance = .auto,
            webMemoryMegabytes: Int? = nil, pinnedWebPort: UInt16? = nil,
            neverAnalysed: [String] = ScannerCommand.defaultNeverSource,
            treatedAsTests: [String] = ScannerCommand.defaultTestPatterns
        ) {
            self.idleTimeout = idleTimeout
            self.lastPorts = lastPorts
            self.menuBarIcon = menuBarIcon
            self.stayResident = stayResident
            self.appearance = appearance
            self.webMemoryMegabytes = webMemoryMegabytes
            self.pinnedWebPort = pinnedWebPort
            self.neverAnalysed = neverAnalysed
            self.treatedAsTests = treatedAsTests
        }

        /// Written out because two legacy names have to be READ and must
        /// never be written. A synthesized `CodingKeys` has a case per
        /// property and nothing else, so the migration below could not name
        /// the keys it needs to migrate from.
        enum CodingKeys: String, CodingKey {
            case idleTimeout, lastPorts, menuBarIcon, stayResident, appearance
            case webMemoryMegabytes, pinnedWebPort, neverAnalysed, treatedAsTests
            case projectNames
            /// The shape these had for one build. Read to migrate, never
            /// encoded — `encode(to:)` only visits keys that are properties.
            case alsoNeverAnalysed, alsoTreatedAsTests
        }

        /// ⚠ Written out because `CodingKeys` carries two legacy names that
        /// are not properties, and the synthesized encoder needs a property
        /// per case. Encoding only the real fields is also the point: the
        /// migration reads `alsoNeverAnalysed` once and this makes sure it
        /// is never written back, so the old shape dies out instead of
        /// lingering in every file for ever.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(idleTimeout, forKey: .idleTimeout)
            try container.encodeIfPresent(lastPorts, forKey: .lastPorts)
            try container.encode(menuBarIcon, forKey: .menuBarIcon)
            try container.encode(stayResident, forKey: .stayResident)
            try container.encode(appearance, forKey: .appearance)
            try container.encodeIfPresent(webMemoryMegabytes, forKey: .webMemoryMegabytes)
            try container.encodeIfPresent(pinnedWebPort, forKey: .pinnedWebPort)
            try container.encode(neverAnalysed, forKey: .neverAnalysed)
            try container.encode(treatedAsTests, forKey: .treatedAsTests)
            try container.encodeIfPresent(projectNames, forKey: .projectNames)
        }

        /// ⚠ **Written out, because a synthesized `init(from:)` does not use
        /// a property's default when the key is missing — it throws.** Every
        /// field below is new, so every preferences file already on disk
        /// lacks all of them; with the synthesized initialiser the decode
        /// would fail, `load()` would fall back to `Stored()` "and say so",
        /// and the user's idle interval and remembered ports would be
        /// silently reset by the release that added a menu bar switch. That
        /// is the migration `lastPorts` avoided by being Optional, done once
        /// for every field rather than by making them all Optional.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Stored()
            idleTimeout =
                try values.decodeIfPresent(IdleTimeout.self, forKey: .idleTimeout)
                ?? fallback.idleTimeout
            lastPorts = try values.decodeIfPresent(LastPorts.self, forKey: .lastPorts)
            menuBarIcon =
                try values.decodeIfPresent(Bool.self, forKey: .menuBarIcon)
                ?? fallback.menuBarIcon
            stayResident =
                try values.decodeIfPresent(Bool.self, forKey: .stayResident)
                ?? fallback.stayResident
            // ⚠ `decodeIfPresent`, and an unknown value is the system's choice
            // rather than a throw: a file written by a later Oilbird must not
            // cost an earlier one every other setting in it.
            appearance =
                (try? values.decodeIfPresent(Appearance.self, forKey: .appearance))
                ?? fallback.appearance
            webMemoryMegabytes = try values.decodeIfPresent(
                Int.self, forKey: .webMemoryMegabytes)
            pinnedWebPort = try values.decodeIfPresent(UInt16.self, forKey: .pinnedWebPort)
            projectNames = try values.decodeIfPresent([String: String].self, forKey: .projectNames)
            // ⚠ The previous shape, folded in rather than dropped: one build
            // kept the user's ADDITIONS under another key, and reading only
            // the new one discards them silently.
            let addedBefore =
                try values.decodeIfPresent([String].self, forKey: .alsoNeverAnalysed) ?? []
            neverAnalysed =
                try values.decodeIfPresent([String].self, forKey: .neverAnalysed)
                ?? (fallback.neverAnalysed
                    + addedBefore.filter {
                        !fallback.neverAnalysed.contains($0)
                    })
            let testsAddedBefore =
                try values.decodeIfPresent([String].self, forKey: .alsoTreatedAsTests) ?? []
            treatedAsTests =
                try values.decodeIfPresent([String].self, forKey: .treatedAsTests)
                ?? (fallback.treatedAsTests
                    + testsAddedBefore.filter {
                        !fallback.treatedAsTests.contains($0)
                    })
        }
    }

    /// A malformed preferences file **fails closed to the defaults** and says
    /// so, rather than refusing to launch.
    ///
    /// This is the one place Oilbird deliberately does not fail closed in the
    /// strict sense, and the reason is narrow: nothing here can corrupt
    /// anything. A bad *port* would be different, which is why ports are not
    /// configurable at all — the OS assigns them.
    public static func load() -> Stored {
        guard let data = FileManager.default.contents(atPath: Paths.config.path) else {
            return Stored()
        }
        guard let decoded = try? PropertyListDecoder().decode(Stored.self, from: data) else {
            Log.warn("preferences could not be read; using defaults")
            return Stored()
        }
        return decoded
    }

    public static func save(_ stored: Stored) throws {
        try FileManager.default.createDirectory(
            at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(stored).write(to: Paths.config, options: .atomic)
    }

    /// Should the server stop, given how long nothing has used it?
    ///
    /// Whoever started the services does not decide this — a GUI, a CLI
    /// invocation and an agent may all be attached, and none of them owns the
    /// lifetime.
    public static func shouldStopWhenIdle(since lastUse: Date, now: Date = Date()) -> Bool {
        guard let limit = load().idleTimeout.seconds else { return false }
        return now.timeIntervalSince(lastUse) >= limit
    }
}
