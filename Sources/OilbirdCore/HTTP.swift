import Foundation

/// Every HTTP request Oilbird makes, and the two things they all have in
/// common.
///
/// **No cookies.** `URLSession.shared` carries a process-wide cookie jar, and
/// SonarQube sets a `JWT-SESSION` cookie — which it then invalidates whenever
/// the account's password changes. On the next call that dead cookie is sent
/// automatically, and SonarQube prefers a session cookie over the
/// `Authorization` header: correct credentials, `401`, no body, nothing in the
/// server log. Provisioning failed there on every machine, and the same jar
/// would keep doing it in ways that depend on the order of unrelated calls.
/// Oilbird's requests authenticate per request. A jar can only carry state
/// nobody asked for between calls that were meant to be independent.
///
/// **No response cache.** These endpoints are polled for state — `is the
/// server up`, `did the gate pass` — and a cached 200 is a wrong answer with
/// the confidence of a right one. It also stops `URLCache` filling the
/// container with a copy of everything downloaded.
///
/// One place, because both of those are rules rather than preferences, and a
/// rule stated in three call sites is a rule that will be right in two of them.
public enum HTTP {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
