import Foundation
import OilbirdCore
import OilbirdModel

func secretsTests() {
    Harness.suite("Secrets — held here, never handed out") {
        Harness.test("generated passwords are long and never repeat") {
            let a = Secrets.generatePassword()
            let b = Secrets.generatePassword()
            // 64 hex characters carry the 256 bits; the four that follow carry
            // the character classes a server may insist on.
            Harness.expectEqual(a.count, 68, "not 256 bits of hex plus a policy suffix")
            Harness.expectEqual(String(a.prefix(64)).count, 64)
            Harness.expectTrue(
                a.prefix(64).allSatisfy(\.isHexDigit), "the entropy is not hex")
            Harness.expectTrue(a != b, "two generated passwords collided")
        }

        // SonarQube refuses a password with no uppercase character, and it
        // refuses it during provisioning where nobody sees the message, so no
        // first run completes on any machine.

        // Asserted over MANY samples: the classes must hold by construction,
        // or a generator that satisfies them usually passes and strands
        // whoever draws the exception.
        Harness.test("every generated password satisfies the server's policy") {
            var sawUpper = 0, sawLower = 0, sawDigit = 0, sawSymbol = 0
            let samples = 200
            for _ in 0..<samples {
                let password = Secrets.generatePassword()
                if password.contains(where: { $0.isUppercase }) { sawUpper += 1 }
                if password.contains(where: { $0.isLowercase }) { sawLower += 1 }
                if password.contains(where: { $0.isNumber }) { sawDigit += 1 }
                if password.contains(where: { !$0.isLetter && !$0.isNumber }) { sawSymbol += 1 }
            }
            Harness.expectEqual(sawUpper, samples, "a password had no uppercase letter")
            Harness.expectEqual(sawLower, samples, "a password had no lowercase letter")
            Harness.expectEqual(sawDigit, samples, "a password had no digit")
            Harness.expectEqual(sawSymbol, samples, "a password had no symbol")
        }

        // The value goes into a Java properties file, where a backslash escapes
        // the next character and a trailing one continues the line: the
        // password reads back wrong, or eats the line below, on some runs.
        Harness.test("a generated password cannot break the file it is written into") {
            let forbidden: Set<Character> = ["\\", "\"", "'", "#", "=", ":", "\n", "\r"]
            for _ in 0..<200 {
                let password = Secrets.generatePassword()
                Harness.expectTrue(
                    !password.contains(where: forbidden.contains),
                    "a generated password contained a character that is punctuation downstream")
            }
        }

        // A file that is briefly world-readable is world-readable. The mode is
        // set on the descriptor, not afterwards.
        Harness.test("credentials are stored 0600") {
            let stored = Secrets.Stored(
                databasePassword: Secrets.generatePassword(),
                adminPassword: Secrets.generatePassword(),
                analysisToken: "squ_" + Secrets.generatePassword(bytes: 10))
            try? Secrets.save(stored)
            guard
                let mode = try? FileManager.default.attributesOfItem(
                    atPath: Paths.State.credentials.path)[.posixPermissions] as? Int
            else {
                Harness.expectTrue(false, "no credentials file was written")
                return
            }
            Harness.expectEqual(mode & 0o077, 0, "group or other can read the credentials")
        }

        Harness.test("what was saved is what comes back") {
            let stored = Secrets.Stored(
                databasePassword: "db-secret-value", adminPassword: "admin-secret-value",
                analysisToken: "squ_token_value")
            try? Secrets.save(stored)
            let loaded = Secrets.load()
            Harness.expectEqual(loaded?.databasePassword, "db-secret-value")
            Harness.expectEqual(loaded?.analysisToken, "squ_token_value")
        }

        // The belt. The braces are that secrets never enter argv at all --
        // a scrubber that is the ONLY defence eventually misses a format it
        // was not written for.
        Harness.test("a stored secret is scrubbed out of anything log-bound") {
            let stored = Secrets.Stored(
                databasePassword: "hunter2hunter2hunter2", adminPassword: "correct-horse-battery",
                analysisToken: "squ_abcdefghijklmnop")
            try? Secrets.save(stored)
            let line = "exec /bin/psql --password=hunter2hunter2hunter2 --token squ_abcdefghijklmnop"
            let scrubbed = Secrets.redact(line)
            Harness.expectTrue(!scrubbed.contains("hunter2hunter2hunter2"), "password survived")
            Harness.expectTrue(!scrubbed.contains("squ_abcdefghijklmnop"), "token survived")
            Harness.expectTrue(scrubbed.contains("«redacted»"))
        }

        Harness.test("a short value is not scrubbed, because it would eat the log") {
            let stored = Secrets.Stored(
                databasePassword: "ab", adminPassword: "cd", analysisToken: nil)
            try? Secrets.save(stored)
            Harness.expectEqual(Secrets.redact("a table about ab and cd"), "a table about ab and cd")
        }
    }
}

func provisioningTests() {
    Harness.suite("Provisioning — the default account is rotated, not offered") {
        // A generated password can contain characters that are reserved in a
        // form body. Unencoded, one of them truncates the request and the
        // account is left on its default.
        Harness.test("form bodies percent-encode their values") {
            let body = Provisioning.form(["password": "a&b=c d+e", "login": "admin"])
            Harness.expectTrue(!body.contains("a&b=c"), "a reserved character went through raw")
            Harness.expectTrue(body.contains("login=admin"))
            Harness.expectTrue(body.contains("%26"), "& was not encoded")
        }

        Harness.test("fields are ordered, so a body is reproducible") {
            let once = Provisioning.form(["b": "2", "a": "1", "c": "3"])
            let twice = Provisioning.form(["c": "3", "a": "1", "b": "2"])
            Harness.expectEqual(once, twice)
        }

        Harness.test("basic auth is encoded, not concatenated") {
            let header = Provisioning.basic(user: "admin", password: "admin")
            Harness.expectTrue(header.hasPrefix("Basic "))
            Harness.expectEqual(header, "Basic " + Data("admin:admin".utf8).base64EncodedString())
        }
    }
}
