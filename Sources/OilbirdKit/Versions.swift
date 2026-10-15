import Foundation
import OilbirdCore
import OilbirdModel

/// What this build pins against what is actually on the disk.
///
/// `Pinned` answers the first half and says in its own comment that the two
/// must be kept apart: *"'pinned' and 'installed' differing is exactly the
/// thing a person asking this question is trying to find out."* This is the
/// pair, so the window can show them side by side rather than showing one
/// and implying the other — which is what `doctor` did for the scanner row.
extension Oilbird {
    public struct VersionRow: Sendable, Equatable {
        public let id: String
        public let pinned: String
        /// `nil` when nothing is installed. Not "unknown" and not the
        /// pinned string: absence is the honest answer for a dependency
        /// that has never been downloaded, and reporting the pinned
        /// version there is precisely the lie this pair exists to stop.
        public let installed: String?
        /// What is actually on disk, read from the install itself.
        ///
        /// ⚠ Separate from `installed`, and it exists because the pane read
        /// "No install recorded" four times on a machine with a running
        /// SonarQube, a JDK, a PostgreSQL and a scanner all plainly working.
        /// True — the record is written on install and these predate the
        /// code that writes it — and useless: it looked like a fault, and
        /// the one question the pane exists to answer went unanswered.
        ///
        /// It is NOT merged into `installed`, because they are different
        /// claims. A record says Oilbird put this here and knows what it
        /// put. This says a file on disk names a version. Presence on disk
        /// is not presence, so it is worded as found, never as
        /// installed, and points at Doctor for the difference.
        public let detected: String?
        public let licence: String

        public init(
            id: String, pinned: String, installed: String?, detected: String? = nil,
            licence: String
        ) {
            self.id = id
            self.pinned = pinned
            self.installed = installed
            self.detected = detected
            self.licence = licence
        }

        /// True when the two disagree — a bump this build has not applied,
        /// or a downgrade.
        public var differs: Bool { installed != nil && installed != pinned }

        /// `↑ scanner 7.3.0.5189 → 7.4.0.0`, the line a pending bump shows.
        public var change: String? {
            guard let installed, installed != pinned else { return nil }
            return "↑ \(id) \(installed) → \(pinned)"
        }
    }

    /// One row per dependency, in install order.
    public static func versionTable() throws -> [VersionRow] {
        try pinned().map { entry in
            VersionRow(
                id: entry.id,
                pinned: entry.version,
                installed: DependencyID(rawValue: entry.id)
                    .flatMap { Install.installedEntry($0)?.version },
                detected: detectedVersion(entry.id),
                licence: entry.licence)
        }
    }

    /// The version the install on disk names, or nil if there is no install.
    ///
    /// `detect()` and not `verify()`: verifying runs the thing, which for
    /// the scanner means a real fixture analysis against a live server.
    /// A settings pane may not cost that.
    private static func detectedVersion(_ id: String) -> String? {
        guard let known = DependencyID(rawValue: id),
            let dependency = dependencies.first(where: { $0.id == known })
        else { return nil }
        if case .present(let version) = dependency.detect() { return version }
        return nil
    }
}
