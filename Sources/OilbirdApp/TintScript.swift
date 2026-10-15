import OilbirdKit
import WebKit

/// Deliberately NOT called `Tint`: that is a core domain name, and a local type
/// shadowing one leaves the boundary gate unable to tell a legitimate local
/// reference from a forbidden cross-domain one. It flagged the first attempt,
/// which was the gate being right.
enum SonarTint {
    /// The WebKit wrapper. The palette and the escaping live in the core, where
    /// they are tested; this is the two lines that genuinely need WebKit.
    static var userScript: WKUserScript {
        WKUserScript(
            source: Oilbird.tintScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
