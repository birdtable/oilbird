import Foundation
import OilbirdCore

/// What the server and Oilbird between them hold about one project.
///
/// ⚠ An extension in its own file, not a separate type. `Oilbird` is
/// the one barrel a client imports and that is deliberate; what was not
/// deliberate is all of it living in one 1,877-line file. Splitting the
/// FILE changes nothing a caller can see.
extension Oilbird {
    /// What the server and Oilbird between them currently hold.
    public static func configuration(of key: String) async throws -> Configuration {
        let attachment = Idle.Attachment(reason: "configure")
        defer { withExtendedLifetime(attachment) {} }
        let (running, token) = try await connected()
        let settings = await SonarAPI.projectSettings(
            base: base(running.webPort), token: token, key: key)
        return Configuration(
            project: key, chosenName: chosenName(key), tags: settings.tags,
            newCode: describe(settings), newCodeInherited: settings.newCodeInherited,
            exclusions: settings.exclusions,
            branch: await SonarAPI.mainBranch(
                base: base(running.webPort), token: token, key: key))
    }

    /// The new-code rule in the words a person uses for it.
    public static func describe(_ settings: SonarAPI.ProjectSettings) -> String? {
        guard let type = settings.newCodeType else { return nil }
        switch type {
        case "PREVIOUS_VERSION": return "since the previous version"
        case "NUMBER_OF_DAYS":
            return "the last " + counted(Int(settings.newCodeValue ?? "") ?? 0, "day")
        case "REFERENCE_BRANCH":
            return "compared with " + (settings.newCodeValue ?? "another branch")
        case "SPECIFIC_ANALYSIS": return "since one chosen analysis"
        default: return type.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }

    /// What a write did, in the server's words when it refused.
    public enum Wrote: Sendable, Equatable {
        case done
        case refused(String)
    }

    /// ⚠ **Every one of these reads back what it wrote.** The
    /// recurring failure of this codebase is *the call succeeded, returned
    /// well-formed data, and the data was wrong* — a write that reports
    /// success on a 2xx and never looks is that failure with a new name.
    public static func tag(_ key: String, _ tags: [String]) async throws -> Wrote {
        let (running, token) = try await connected()
        let host = base(running.webPort)
        let wanted = tags.map { $0.lowercased() }.filter { !$0.isEmpty }
        if let said = await SonarAPI.setTags(base: host, token: token, key: key, tags: wanted) {
            return .refused(said)
        }
        let after = await SonarAPI.projectSettings(base: host, token: token, key: key)
        guard Set(after.tags) == Set(wanted) else {
            return .refused(
                "the server accepted it and then reported "
                    + (after.tags.isEmpty ? "no tags" : after.tags.joined(separator: ", ")))
        }
        return .done
    }

    public static func newCode(_ key: String, _ type: String, value: String?) async throws
        -> Wrote
    {
        let (running, token) = try await connected()
        let host = base(running.webPort)
        if let said = await SonarAPI.setNewCode(
            base: host, token: token, key: key, type: type, value: value)
        {
            return .refused(said)
        }
        let after = await SonarAPI.projectSettings(base: host, token: token, key: key)
        guard after.newCodeType == type else {
            return .refused(
                "the server accepted it and then reported \(after.newCodeType ?? "nothing")")
        }
        // ⚠ The VALUE is checked too. `NUMBER_OF_DAYS` with no value, or
        // with a different one, is a different rule wearing the same word —
        // and a read-back that only compares the type would pass it.
        if let value, !value.isEmpty, after.newCodeValue != value {
            return .refused(
                "the server accepted \(type) but reported \(after.newCodeValue ?? "no value")")
        }
        return .done
    }

    public static func exclude(_ key: String, _ patterns: [String]) async throws -> Wrote {
        let (running, token) = try await connected()
        let host = base(running.webPort)
        let wanted = patterns.filter { !$0.isEmpty }
        if let said = await SonarAPI.setExclusions(
            base: host, token: token, key: key, patterns: wanted)
        {
            return .refused(said)
        }
        let after = await SonarAPI.projectSettings(base: host, token: token, key: key)
        guard Set(after.exclusions) == Set(wanted) else {
            return .refused(
                "the server accepted it and then reported "
                    + (after.exclusions.isEmpty
                        ? "no exclusions" : after.exclusions.joined(separator: ", ")))
        }
        return .done
    }

    /// Rename the main branch.
    ///
    /// ⚠ `set_main` is deliberately not offered. Community Build analyses
    /// everything onto a single branch — branch analysis is a commercial
    /// feature — so there is never a second branch to promote, and a command
    /// offering the choice would be offering nothing.
    public static func renameBranch(_ key: String, to name: String) async throws -> Wrote {
        let (running, token) = try await connected()
        let host = base(running.webPort)
        if let said = await SonarAPI.renameMainBranch(
            base: host, token: token, key: key, to: name)
        {
            return .refused(said)
        }
        guard await SonarAPI.mainBranch(base: host, token: token, key: key) == name else {
            return .refused("the server accepted it and then reported another name")
        }
        return .done
    }

    /// What a project is to be called from its next scan onward.
    ///
    /// ⚠ **Nothing here renames anything on the server, and it cannot.**
    /// SonarQube has no rename endpoint — `api/projects` offers `create`,
    /// `delete`, `bulk_delete`, `update_key` and `update_visibility`, and
    /// `include_internals=true` adds only `update_default_visibility`. The
    /// one thing that sets a name is an ANALYSIS carrying
    /// `sonar.projectName`, verified on the pinned server: re-analysing a
    /// key with a different name changed `name-test` to `Name Test,
    /// Renamed` and kept its history.
    ///
    /// So this records the choice, and every surface that offers it says
    /// the name lands at the next scan. Reporting a rename that has not
    /// happened is the failure this codebase keeps finding: the call
    /// succeeded, the answer was well-formed, and it described nothing.
    public static func name(_ key: String, as chosen: String?) throws {
        var stored = Preferences.load()
        var names = stored.projectNames ?? [:]
        let trimmed = chosen?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name is a REMOVAL, not a name: it puts the project back
        // to being called after its directory.
        if let trimmed, !trimmed.isEmpty { names[key] = trimmed } else { names[key] = nil }
        stored.projectNames = names.isEmpty ? nil : names
        try Preferences.save(stored)
    }

    /// The name a project will carry after its next scan, if one was chosen.
    public static func chosenName(_ key: String) -> String? {
        Preferences.load().projectNames?[key]
    }
}
