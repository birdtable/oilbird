import Darwin
import Foundation
import OilbirdCore

/// What the engine is doing, in the detail a bug report needs.
///
/// ⚠ "Is it actually up?" must be answerable without the CLI, and the GUI
/// could answer only "running" or "paused" — one word from a pill. Which
/// process, on which port, since when, and how much of the machine it is
/// holding were all knowable and none of them were shown anywhere but
/// `oilbird status`.
///
/// Every field is read from disk or from the kernel at the moment it is
/// asked for. Nothing here is remembered, for the reason the whole app now
/// polls: the CLI, an agent and the idle watchdog all change this state and
/// none of them can call back into a running window.
extension Oilbird {
    public struct EngineDetail: Sendable, Equatable {
        /// The supervising process Oilbird launched.
        public let pid: Int32
        /// Its process group — the JVMs and PostgreSQL are all in it, which
        /// is why one `killpg` stops the lot and why the memory below is a
        /// sum over the group rather than over one process.
        public let group: Int32?
        public let webPort: UInt16
        public let databasePort: UInt16
        public let startedAt: Date
        /// Resident bytes across the whole group, or `nil` when the kernel
        /// would not say. Not zero: zero is a number, and "the engine is
        /// using no memory" is a false one.
        public let residentBytes: Int64?
        /// How many processes the group actually holds. A group of one is
        /// how a half-dead stack presents.
        public let processes: Int

        public var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

        /// "2h 14m", "3m", "12s" — the shortest true form.
        public var uptimeLabel: String {
            let seconds = Int(max(0, uptime))
            if seconds < 60 { return "\(seconds)s" }
            if seconds < 3600 { return "\(seconds / 60)m" }
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
    }

    /// The engine, or `nil` when there is not one.
    ///
    /// `nil` rather than a struct full of dashes: a pane that has nothing to
    /// report should say the engine is not running, not print a table of
    /// empty cells and let the reader work it out.
    public static func engineDetail() -> EngineDetail? {
        guard let running = status(), let record = Supervise.readRecord(),
            Supervise.isAlive(record.app)
        else { return nil }
        let members = record.group.map { Supervise.Kernel.members(ofGroup: $0) } ?? [record.app]
        let resident = members.compactMap(residentBytes(of:)).reduce(0, +)
        return EngineDetail(
            pid: record.app,
            group: record.group,
            webPort: running.webPort,
            databasePort: running.databasePort,
            startedAt: record.recorded,
            residentBytes: resident > 0 ? resident : nil,
            processes: members.count)
    }

    /// One process's resident set, from the kernel.
    ///
    /// `proc_pid_rusage` rather than shelling out to `ps`: this is read
    /// every time the Engine pane refreshes, and a subprocess per refresh
    /// to print one number is not a cost worth paying. `nil` on refusal —
    /// a process that exited between the group listing and this call is
    /// ordinary, and counting it as zero would quietly understate the
    /// total instead.
    static func residentBytes(of pid: Int32) -> Int64? {
        var info = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard read == 0 else { return nil }
        return Int64(info.ri_resident_size)
    }
}
