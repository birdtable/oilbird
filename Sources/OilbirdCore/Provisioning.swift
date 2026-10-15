import Foundation
import OilbirdModel

/// First-run credential provisioning against a freshly started SonarQube.
///
/// A new instance has exactly one account, `admin`/`admin`, and the server
/// logs a warning on every boot until it changes. An unrotated instance is an
/// open admin console for anyone who can reach the port — so this runs before
/// the UI is usable, not as a setting the user might find.
public enum Provisioning {
    /// Rotates the default account and mints an analysis token.
    ///
    /// Returns nothing: the caller gets no credential. That is the point.
    public static func run(base: URL) async throws {
        var stored =
            Secrets.load()
            ?? Secrets.Stored(
                databasePassword: Secrets.generatePassword(),
                adminPassword: Secrets.generatePassword(), analysisToken: nil)

        if stored.analysisToken != nil { return }

        Log.phase("provision credentials")

        // Runs again after any failure over two steps that cannot be undone, so
        // it ASKS the server what it accepts. Rotating is a one-way door, and
        // assuming a fresh instance reports a dead end on a healthy one.
        if try await accepts(base: base, password: stored.adminPassword) {
            Log.info("the admin account is already rotated; resuming")
        } else if try await accepts(base: base, password: "admin") {
            // Rotate before minting: a token created under admin/admin would
            // leave a window where the token exists and the default still
            // works.
            let rotated = Secrets.generatePassword()
            try await changeAdminPassword(base: base, from: "admin", to: rotated)
            stored.adminPassword = rotated

            // ⚠ Saved HERE, never at the end: the rotation has happened, so this
            // variable is the only copy of the credential the server now
            // demands. Reinstalling does not recover it.
            try Secrets.save(stored)
        } else {
            throw OilbirdError(
                .verifyFailed, "The server's admin password has already been changed.",
                recovery: .reportIssue("Report an issue"),
                underlying: "neither the stored password nor the default is accepted")
        }

        stored.analysisToken = try await generateToken(
            base: base, admin: stored.adminPassword)
        try Secrets.save(stored)
        Log.info("credentials provisioned and stored 0600")
    }

    /// Does the server accept this password for `admin`?
    ///
    /// `api/authentication/validate` answers `200` either way and puts the
    /// verdict in the body, so the status code is not the answer — reading it
    /// as one would report every wrong password as correct.
    static func accepts(base: URL, password: String) async throws -> Bool {
        var request = URLRequest(url: base.appending(path: "api/authentication/validate"))
        request.setValue(
            basic(user: "admin", password: password), forHTTPHeaderField: "Authorization")
        let (data, _) = try await HTTP.session.data(for: request)
        struct Validation: Decodable { let valid: Bool }
        return (try? JSONDecoder().decode(Validation.self, from: data))?.valid ?? false
    }

    static func changeAdminPassword(base: URL, from old: String, to new: String) async throws {
        var request = URLRequest(url: base.appending(path: "api/users/change_password"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(basic(user: "admin", password: old), forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            form(["login": "admin", "previousPassword": old, "password": new]).utf8)

        let (data, response) = try await HTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 204 is success. 401 means the default has already been changed by
        // hand, which is a legitimate state Oilbird cannot recover from
        // silently -- it does not know the password.
        guard code == 204 else {
            throw OilbirdError(
                .verifyFailed,
                code == 401
                    ? "The server's admin password has already been changed."
                    : "Oilbird could not secure the server's admin account.",
                recovery: .reportIssue("Report an issue"),
                // Dropping the body leaves "change_password returned 400" and
                // nothing else, the same uselessness as `pg_ctl` reporting a
                // failed start with the reason in a file it never prints.
                underlying: "change_password returned \(code): \(reason(data))")
        }
    }

    /// SonarQube's error body, reduced to its messages.
    ///
    /// The shape is `{"errors":[{"msg":"..."}]}`. Anything else -- an HTML
    /// error page, an empty body -- is passed through as text rather than
    /// swallowed, because an unexpected body is itself the diagnosis.
    static func reason(_ data: Data) -> String {
        struct Errors: Decodable {
            struct Entry: Decodable { let msg: String }
            let errors: [Entry]
        }
        if let decoded = try? JSONDecoder().decode(Errors.self, from: data), !decoded.errors.isEmpty {
            return decoded.errors.map(\.msg).joined(separator: "; ")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "(no body)" : text.prefix(400).description
    }

    /// What a 401 on an admin call actually means, said once.
    ///
    /// ⚠ Not "try again". Oilbird authenticates as `admin` with a password it
    /// generated and stored, and the ONE thing that invalidates it is a person
    /// changing that password from My Account → Security in the dashboard.
    /// Nothing on that page says the desktop app is holding the credential.
    /// Reported as a retry, this sent the user to repeat an action that could
    /// never work — the same dead end as the revoked analysis token, one layer
    /// down, and it disables the recovery that handles the revoked token too.
    static func adminRejected(_ action: String, _ code: Int, _ data: Data) -> OilbirdError {
        OilbirdError(
            .credentialRejected,
            "The server no longer accepts Oilbird's administrator password. "
                + "It was almost certainly changed from the dashboard, under "
                + "My Account → Security.",
            recovery: .chooseAlternative("Set the password back"),
            underlying: "user_tokens/\(action) returned \(code): \(reason(data))")
    }

    /// The one name Oilbird's token goes by.
    ///
    /// Fixed rather than unique-per-run so that a token left behind by an
    /// earlier install can be found and revoked instead of accumulating.
    public static let tokenName = "oilbird"

    /// Replaces Oilbird's analysis token: revoke the old one, then mint.
    ///
    /// ⚠ Revoke FIRST, and not only for tidiness. `user_tokens/generate`
    /// refuses a name that already exists, so a second call under the same
    /// name fails outright — which is what a user hit by revoking the token
    /// through the dashboard and asking Oilbird to recover. Revoking is
    /// idempotent: it succeeds whether or not the name is in use, so this is
    /// safe on a first run too.
    ///
    /// This is also why Oilbird no longer leaves a trail of dead tokens on
    /// the account. Every reprovision used to mint a new one and abandon the
    /// last.
    public static func mintToken(base: URL, admin: String) async throws -> String {
        try await revokeToken(base: base, admin: admin, name: tokenName)
        return try await generateToken(base: base, admin: admin)
    }

    /// Revokes a token by name. A name that does not exist is not an error.
    public static func revokeToken(base: URL, admin: String, name: String) async throws {
        var request = URLRequest(url: base.appending(path: "api/user_tokens/revoke"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            basic(user: "admin", password: admin), forHTTPHeaderField: "Authorization")
        request.httpBody = Data(form(["name": name]).utf8)

        let (data, response) = try await HTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 204 is success, and so is a name that was never there.
        guard code == 204 || code == 200 else {
            guard code != 401, code != 403 else { throw adminRejected("revoke", code, data) }
            throw OilbirdError(
                .verifyFailed, "Oilbird could not replace its analysis token.",
                recovery: .retry("Try again"),
                underlying: "user_tokens/revoke returned \(code): \(reason(data))")
        }
    }

    static func generateToken(base: URL, admin: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "api/user_tokens/generate"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            basic(user: "admin", password: admin), forHTTPHeaderField: "Authorization")
        request.httpBody = Data(form(["name": tokenName]).utf8)

        let (data, response) = try await HTTP.session.data(for: request)
        let generated = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard generated != 401, generated != 403 else {
            throw adminRejected("generate", generated, data)
        }
        guard generated == 200,
            let payload = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else {
            throw OilbirdError(
                .verifyFailed, "Oilbird could not create an analysis token.",
                recovery: .retry("Try again"),
                underlying: "user_tokens/generate returned \(generated): \(reason(data))")
        }
        return payload.token
    }

    struct TokenResponse: Decodable { let token: String }

    public static func basic(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// Form-encodes a body. Values are percent-encoded, so a generated password
    /// containing a reserved character cannot truncate the request.
    public static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
