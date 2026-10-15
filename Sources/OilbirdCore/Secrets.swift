import Foundation
import OilbirdModel

/// Holds the credentials — nothing else may.
///
/// Clients never receive either value. An agent that needs a token to ask a
/// question has been handed a secret it should not hold and a setup step it
/// cannot perform, so `OilbirdKit` injects them and returns data.
///
/// Redaction is **structural, not a filter**: the token reaches the scanner
/// through the environment and never through argv, which is what makes it safe
/// to log a subprocess command line verbatim.
public enum Secrets {
    public struct Stored: Sendable, Codable {
        public var databasePassword: String
        public var adminPassword: String
        public var analysisToken: String?

        public init(databasePassword: String, adminPassword: String, analysisToken: String?) {
            self.databasePassword = databasePassword
            self.adminPassword = adminPassword
            self.analysisToken = analysisToken
        }
    }

    /// Generated, not derived. 256 bits from the system CSPRNG.
    ///
    /// Hex is the core because this value is written into a Java properties
    /// file, posted in a form body and handed to `initdb`, and a character
    /// that is punctuation in one of those is a bug that shows up for some
    /// users on some runs and never reproduces.
    ///
    /// ⚠ Hex alone is not a password any more. SonarQube refuses one without
    /// an uppercase letter — `{"result":"Password must contain at least one
    /// uppercase character"}` — and hex is lowercase, so every password this
    /// produced was rejected at `change_password` and **no first run could
    /// ever complete**. Nobody saw the reason, because the response body was
    /// discarded and the log line was queued behind an `exit`.
    ///
    /// The classes are satisfied by construction rather than by generating and
    /// re-rolling until one passes: a rejection loop turns a policy nobody
    /// here controls into a program that may not terminate.
    public static func generatePassword(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        // arc4random_buf is the platform CSPRNG and cannot fail.
        arc4random_buf(&bytes, count)
        return bytes.map { String(format: "%02x", $0) }.joined() + policySuffix()
    }

    /// One character from each class a server may insist on, from the same
    /// CSPRNG — so this adds entropy rather than being a known suffix.
    ///
    /// The symbols exclude `\`, `"`, `'`, `#`, `=` and `:`. The first is an
    /// escape in a Java properties file and a trailing one silently continues
    /// the line onto the next; the rest are punctuation in a file format or a
    /// URL this value passes through.
    static func policySuffix() -> String {
        ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "!@$%^&*-_+?"]
            .map { alphabet in
                let offset = Int.random(in: 0..<alphabet.count)
                return String(alphabet[alphabet.index(alphabet.startIndex, offsetBy: offset)])
            }
            .joined()
    }

    public static func load() -> Stored? {
        guard let data = FileManager.default.contents(atPath: Paths.State.credentials.path)
        else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// Written `0600` and never anywhere else.
    ///
    /// The mode is set on the descriptor before the bytes are written, not
    /// after: a file that is briefly world-readable is world-readable.
    public static func save(_ stored: Stored) throws {
        try FileManager.default.createDirectory(
            at: Paths.state, withIntermediateDirectories: true)
        let path = Paths.State.credentials.path
        let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw OilbirdError(
                .clusterCorrupt, "Oilbird could not save its credentials.",
                recovery: .retry("Try again"), underlying: "open(\(path)) failed: \(errno)")
        }
        defer { close(descriptor) }
        // Re-assert the mode: an existing file keeps its own, and O_CREAT's
        // mode argument is ignored when the file already exists.
        _ = fchmod(descriptor, 0o600)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Removes anything that looks like a stored secret from a string bound
    /// for a log.
    ///
    /// The belt, not the braces. The braces are that secrets never enter argv
    /// in the first place — a scrubber that is the only defence will eventually
    /// miss a format it was not written for.
    public static func redact(_ text: String) -> String {
        guard let stored = load() else { return text }
        var scrubbed = text
        for secret in [stored.databasePassword, stored.adminPassword, stored.analysisToken] {
            guard let secret, secret.count >= 8 else { continue }
            scrubbed = scrubbed.replacingOccurrences(of: secret, with: "«redacted»")
        }
        return scrubbed
    }
}
