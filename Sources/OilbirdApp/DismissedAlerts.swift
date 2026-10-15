import WebKit

/// Presses SonarQube's own × on the banners that would otherwise greet every
/// open of the window.
///
/// The obvious route — `api/users/dismiss_notice` — is the wrong one for
/// these, and the difference cost an afternoon: `showNewModesBanner` accepts
/// the call, records `true` against the account, and the strip is *still*
/// there on the next load. It is a different mechanism. SonarQube's
/// `DismissableAlert` keeps its state in the browser, and reads it as a
/// string:
///
///     localStorage.getItem("sonarqube.dismissed_alert." + alertKey) !== "true"
///
/// So this answers exactly that question, for exactly these alerts. It is
/// not a restyle — no selector is matched and no markup is touched — and
/// a key SonarQube renames simply stops matching,
/// which brings the banner back. The failure mode is stock SonarQube, the
/// only acceptable one.
enum SonarDismissals {
    /// The alert keys, in the product's own vocabulary, matched by prefix.
    ///
    /// Prefixes rather than whole keys because two of these are per-page and
    /// per-project: the calculation-change banner appends the qualifier of
    /// the route (`TRK` for projects, `VW` for portfolios) and the CI
    /// banner appends the project key, so the set of exact keys is not
    /// knowable ahead of the page that shows them.
    static let dismissedPrefixes = [
        // "The way in which security, reliability, and maintainability
        // counts and ratings are calculated has changed."
        "sonarqube.dismissed_alert.sonarqube.dismissed_calculation_change_alert",
        // SonarQube's "set up analysis in your favorite CI" banner, shown
        // because the last analysis was not from a CI. For a tool whose point
        // is analysis on your own machine that is not a thing to fix.
        "sonarqube.dismissed_alert.config_ci_pr_deco.",
    ]

    /// ⚠ `.atDocumentStart`. At document end the alert has already read the
    /// key, decided, and rendered — the answer would land one frame too late
    /// and the user would see the strip flash in and out.
    ///
    /// It answers the read rather than writing the value because the keys it
    /// must answer for are only known once the page has decided which
    /// project it is showing. Reads outside these prefixes are handed
    /// straight back to the real `getItem`, so nothing else in the page sees
    /// a different storage than it wrote.
    static var userScript: WKUserScript {
        let list = dismissedPrefixes.map { "'\($0)'" }.joined(separator: ", ")
        let source = """
            (function () {
              var dismissed = [\(list)];
              try {
                var real = Storage.prototype.getItem;
                Storage.prototype.getItem = function (key) {
                  if (typeof key === 'string') {
                    for (var i = 0; i < dismissed.length; i++) {
                      if (key.indexOf(dismissed[i]) === 0) { return 'true'; }
                    }
                  }
                  return real.apply(this, arguments);
                };
              } catch (e) {}
            })();
            """
        return WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
