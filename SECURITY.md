# Security

## Reporting a vulnerability

Report privately, through GitHub's private vulnerability reporting on
this repository — the **Security** tab, *Report a vulnerability*. That
opens a channel visible only to the maintainers.

Do not open a public issue and do not send a pull request that
describes the problem in its diff or its message.

There is no published security contact address and no PGP key. If
GitHub's private reporting is not available to you, open a public issue
that says only that you have something to report and asks for a
channel — no details.

Please include what you have: the version or commit, macOS version, the
steps, and what an attacker gets. There is no bounty programme.

## Supported versions

The latest release receives security fixes. Reports against `main` are
welcome too.

## What Oilbird actually does

Oilbird's job is to make third-party server software work on a
developer's Mac without the developer installing anything first. Read
that sentence as a threat model: the parts of Oilbird worth attacking
are the parts that download, unpack, execute, and hold credentials.

### It downloads and executes third-party software

On first run Oilbird downloads about 1.14 GiB from the vendors'
official origins and runs it on the user's machine:

| what | why |
|---|---|
| Temurin JDK 21 | SonarQube needs a JDK; the JRE inside the SonarQube distribution lacks `jdk.attach` and Elasticsearch will not boot on it |
| PostgreSQL binaries | SonarQube's database |
| SonarQube Community Build | the server itself |
| SonarScanner CLI | the analysis client |

Nothing is vendored into the repository or the app bundle; the bytes
arrive at run time. Every artifact has a pinned version, size and
SHA-256 in `manifest.json`, verified after transfer. A digest mismatch
fails closed and the artifact is discarded — it is never unpacked and
never executed.

Everything Oilbird installs lands under `~/Library/Caches/Oilbird/`.
Oilbird never installs a third-party dependency system-wide, never
writes to Homebrew, and never adopts a PostgreSQL cluster it did not
create. The only thing it ever places outside its own container is a
symbolic link to its own `oilbird` command in `/usr/local/bin`, and only
when the user turns that on in Settings.

### It strips the macOS quarantine attribute, after verifying SHA-256

This is the most security-sensitive thing Oilbird does, and you should
read it here rather than discover it.

Extracted artifacts carry `com.apple.quarantine`, which propagates
through extraction — downloading a jar taints the archive inside it and
every binary extracted from that. Oilbird removes that attribute from
the extracted tree (`xattr -dr com.apple.quarantine`) before running
anything from it, and verifies that the strip took effect.

It has to. The PostgreSQL binaries are Developer ID signed by
EnterpriseDB but **not notarised**: `spctl` reports
`rejected — source=Unnotarized Developer ID`, and a quarantined binary
is `SIGKILL`ed on first exec with exit 137 and no message. Ad-hoc
re-signing does not fix it; removing the attribute is both necessary
and sufficient.

**The ordering is what makes it defensible.** Stripping quarantine is
declining Gatekeeper's opinion of an artifact, and that is only
acceptable because Oilbird has a stronger opinion of its own: a pinned
SHA-256, verified byte-for-byte, before the artifact is unpacked at
all. The strip is therefore unreachable on a corrupted download —
verification fails, the artifact is discarded, and the strip never runs.
It is also confined to Oilbird's own container; nothing outside it is
touched.

If you find a path where the strip can be reached before verification,
or where it can be pointed outside the container, that is a report
worth making.

### It runs local network services

Oilbird starts a PostgreSQL cluster and a SonarQube server as child
processes it owns. Both bind `127.0.0.1` exclusively, on ports assigned
by the OS rather than fixed. Neither is intended to be reachable from
another machine; a listener on any other interface is a bug worth
reporting.

PostgreSQL runs as Oilbird's own cluster with
`listen_addresses=127.0.0.1` and `unix_socket_permissions=0700`, its
socket directory under `/tmp` because `sun_path` is 104 bytes and the
container path is already close to it.

SonarQube starts its own Elasticsearch child, also bound to
`127.0.0.1`. Oilbird does not manage it, but records the descendant set
so that nothing is orphaned when the supervisor dies.

### It generates and stores credentials

Oilbird generates a database password and a SonarQube analysis token on
the user's behalf. They are written to
`~/Library/Application Support/Oilbird/credentials.json` with file mode
`0600`, and never passed on a command line: the password reaches
`initdb` through a temporary `0600` file and SonarQube through its
`0600` configuration file, and the token reaches the scanner through its
environment. No client — the app, the CLI or the MCP server — is ever
handed either value.

A credential in a log, a credential file with looser permissions than
`0600`, or a credential returned outward to a client is a bug worth
reporting.

## Known and accepted

**Oilbird is not notarised.** Release builds are signed ad-hoc rather
than with an Apple Developer ID, so a downloaded build meets Gatekeeper
as an unidentified developer and needs one visit to System Settings ▸
Privacy & Security ▸ Open Anyway. Building from source with `make app`
avoids this: a locally built app is not quarantined. Do not report the
absence of notarisation as a vulnerability; do report a concrete attack
it enables.

Oilbird is licensed under the GNU General Public License v3.0
([`LICENSE`](LICENSE)) and provided without warranty, as that licence
states. Third-party software it downloads is attributed in
[`NOTICE`](NOTICE); Oilbird redistributes none of it.

## Out of scope

- Vulnerabilities in SonarQube, PostgreSQL, Temurin or the SonarScanner
  themselves. Report those to their maintainers. A stale pinned version
  in `manifest.json` that leaves users on a known-vulnerable build *is*
  in scope here.
- Anything that requires an attacker to already have local code
  execution as the user. Oilbird's container is protected by file
  permissions, not by a boundary against its own user.
- The absence of notarisation on its own, as above.
