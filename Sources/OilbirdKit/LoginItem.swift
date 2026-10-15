import Foundation
import OilbirdCore
import OilbirdModel
import ServiceManagement

/// Whether Oilbird starts when the Mac does.
///
/// ⚠ The settings panel carried the sentence *"Nothing Oilbird installs
/// starts at login."* That was true, it was a design decision worth keeping
/// as a default, and it was written as though it were a law of nature. It is
/// a choice, and the person it affects had no way to make it.
///
/// **The system holds the truth, not `Preferences`.** `SMAppService` records
/// the registration itself and the user can revoke it in System Settings ▸
/// General ▸ Login Items without Oilbird being running to hear about it. A
/// stored `Bool` beside that would be a second answer that drifts from the
/// first, which is the defect `EngineVocabulary` was written to end — so
/// there is no `openAtLogin` field in `Preferences.Stored` and this reads
/// the system every time.
///
/// Here rather than in the app for the usual reason: an executable target
/// cannot be `@testable import`-ed, and `ServiceManagement` is not a UI
/// framework, so the state vocabulary belongs where a test can name it.
extension Oilbird {
    public enum LoginItemState: Sendable, Equatable {
        case on
        case off
        /// The user turned it off in System Settings and macOS will not let
        /// the app turn it back on without them. Reported rather than
        /// silently retried, because the switch must not lie about what a
        /// click will do.
        case refusedBySystem
        /// There is no bundle to register — `swift run`, or the CLI. Not an
        /// error and not a failure to report: the question does not apply.
        case unavailable

        public var isOn: Bool { self == .on }
    }

    /// What macOS says right now.
    public static func loginItemState() -> LoginItemState {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .refusedBySystem
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Registers or unregisters Oilbird as a login item.
    ///
    /// The throw carries the system's own message, because the recovery for
    /// every failure here is in System Settings and Oilbird cannot press it
    /// on the user's behalf.
    public static func setLoginItem(_ wanted: Bool) throws {
        guard isBundled else {
            throw OilbirdError(
                .verifyFailed,
                "Oilbird is not running from an application bundle.",
                recovery: .reportIssue("Open the installed Oilbird instead"),
                underlying: "SMAppService.mainApp needs a .app around the executable")
        }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("open at login: \(wanted)")
        } catch {
            throw OilbirdError(
                .verifyFailed,
                wanted
                    ? "macOS would not add Oilbird to your login items."
                    : "macOS would not remove Oilbird from your login items.",
                recovery: .reportIssue("Change it in System Settings ▸ General ▸ Login Items"),
                underlying: "\(error)")
        }
    }

    /// Is the running executable inside a `.app`?
    ///
    /// Asked of the running executable rather than `Bundle.main.bundleURL`,
    /// for the reason `Bundled.swift` gives at length: a bare executable's
    /// `Bundle.main` is a real bundle for the directory it sits in, so
    /// every "is there a bundle?" test written the easy way answers yes.
    static var isBundled: Bool {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()  // Contents/MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Oilbird.app
            .pathExtension == "app"
    }
}
