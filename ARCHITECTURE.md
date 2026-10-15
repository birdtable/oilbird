# Architecture

The map of the code, and the rules that hold its shape.

## Shape

One process supervises two child processes it installed itself — a
PostgreSQL cluster and a SonarQube server, on a JDK it downloaded —
each behind an identical `detect() → install() → verify()` triple, none
resolved through `PATH`, none touching anything the user already had.

```
Oilbird.app  or  oilbird  or  oilbird-mcp
        └── OilbirdKit
                ├── postgres      (child, own port, 127.0.0.1)
                └── sonarqube     (child, 127.0.0.1)
                        └── elasticsearch  (SonarQube's own child)
```

Oilbird supervises two processes; SonarQube supervises its own. Oilbird
does not reach past SonarQube into Elasticsearch, but `Supervise` records
the whole descendant set anyway, because killing the SonarQube
supervisor orphans its children.

## Targets

```
Sources/
├── OilbirdModel/         foundation types. Depends on nothing
├── OilbirdCore/          the domains, one flat folder
├── OilbirdKit/           the barrel, the verb registry and the terminal UI
├── OilbirdApp/           GUI executable   (AppKit; composition only)
├── OilbirdCLI/           CLI executable   (argv, exit codes, --json)
├── OilbirdMCP/           MCP executable   (tool schemas over the same registry)
├── OilbirdChecks/        the build-time checks `make lint` runs
├── OilbirdChecksCLI/     the `oilbird-checks` executable
└── OilbirdBrowseFixture/ a fixture binary for the issue browser's tests
Tests/
└── OilbirdKitTests/      executable target, hand-rolled harness
```

The products are `OilbirdApp`, `oilbird` and `oilbird-mcp`. The GUI
product is deliberately not called `Oilbird`: macOS filesystems are
case-insensitive, so `Oilbird` and `oilbird` would collide both as
build products and as source directories. It is renamed on the way into
`Oilbird.app/Contents/MacOS`.

**Clients import `OilbirdKit` and nothing else.** One dependency, by
design.

**The compiler holds one seam directly.** `OilbirdModel` declares no
dependency, so the compiler enforces that it imports nothing. The rest
is held by checks — see [Enforcement](#enforcement).

A new target needs a reason a folder cannot give: each one costs
`public` inflation on every symbol that crosses it. That is why the
domains live inside `OilbirdCore` as files and caseless `enum`s rather
than as separate targets.

## Domains

`domains.yaml` is the register: every source file belongs to exactly one
domain, and `may_reference` lists which domains each one may use. The
`domains` check reads it. Each domain does one thing, and several are
written as prohibitions, because their value is the refusal rather than
the capability: `Paths`'s worth is not that it builds URLs, it is that
one module names a path and nothing else may.

| domain | owns |
|---|---|
| `Model` | types, IDs, health and state enums, `OilbirdError`. No I/O of any kind |
| `Paths` | every filesystem location, and the state/cache/config split — nothing else may name a path |
| `Log` | the log file every failure state offers to show |
| `Resolver` | every executable path and every child environment — nothing is launched by bare name |
| `Bundled`, `Manifest` | what ships inside the app, and the pinned version, origin, size and digest of each dependency |
| `HTTP` | the configured `URLSession` every request goes through |
| `Fetch` | downloading, resume and digest verification — admits only bytes that match their digest |
| `Install` | extraction, the quarantine strip, atomic placement, idempotency. It is handed verified bytes |
| `Ports`, `Readiness` | OS-assigned ports, and whether a postmaster is actually answering |
| `Owner` | the single-owner lock on the cluster |
| `Child` | constructing a child process — nothing else may |
| `Cluster` | `initdb`, the role and database: the one-time, irreversible act |
| `Supervise` | one running SonarQube's lifetime: start, health, the stop ladder, orphan reaping |
| `Deps` | the four managed dependencies, each a `detect() → install() → verify()` triple |
| `SonarAPI` | every HTTP call to SonarQube — nothing else may |
| `Secrets`, `Provision` | the database password and analysis token, and creating them on first run |
| `Project`, `ScanCmd`, `Scan`, `Scans` | what a directory is, how the scanner is launched, one analysis, and the record of every scan |
| `Prefs`, `Idle`, `Tint`, `CLITool` | preferences, the idle policy, the palette painted over the dashboard, and the opt-in CLI link |
| `Kit` | the barrel the clients see, and the only place a credential is loaded and injected |

`Cluster` is separate from `Supervise` because `initdb` is one-time and
irreversible while starting `postgres` happens every boot — opposite
change disciplines. `Fetch` is separate from `Install` because fetching
is network, retry and digest while installing is filesystem, atomic
rename and idempotency; different test shapes are the third signal that
they are two domains.

The refusals in the matrix worth knowing before you write code:

- **`SonarAPI` reaches only `Model` and `HTTP`** — not even `Paths`. Its
  inputs are a base URL and a token, passed in. That is what makes it
  testable against a fixture server.
- **`Secrets` reaches nothing outward**, so nothing can pull a secret
  through it, and no client ever receives a credential: `Kit` loads the
  token and injects it.
- **`Child` is the only route to a process.** Without this you get
  orphaned `postgres` processes and no single kill-on-quit.
- **`Idle` may not reach `Supervise` or `Cluster`.** The stop action is
  injected by `Kit`, the only place that knows how to stop the engine.

## The three roots

`Paths` names **three roots**, not one container with subdirectories,
and they are told apart by **what losing them costs**:

| root | path | losing it costs |
|---|---|---|
| state | `~/Library/Application Support/Oilbird/` | everything — the cluster holds every scan you have run |
| cache | `~/Library/Caches/Oilbird/` | a download |
| config | `~/Library/Preferences/com.birdtable.oilbird.plist` | your preferences |

```
<state>/                        never cleared to free space
├── postgres/data/              the cluster: projects, issues, history
├── credentials.json            0600 — DB password, analysis token
├── manifest.json               what is actually installed
├── scans/                      the record and log of every scan
└── run/                        pidfiles, the cluster lock

<cache>/                        rederivable, a download away
├── jdk/  postgres/  sonarqube/  sonar-scanner/
├── partials/                   resumable downloads, keyed by SHA-256
└── logs/
```

The split is not tidiness. **Every managed dependency lives under
`<cache>`** — 1.14 GiB of it, all rederivable — and nothing under
`<cache>` is state. That is the only reason "reclaim disk space" can be
offered at all: on a flat container, "reset Oilbird" and "reclaim disk"
would be the same dangerous operation.

One location is deliberately outside all three: PostgreSQL's Unix
socket directory lives under `/tmp`, because `sun_path` is 104 bytes
and `~/Library/Application Support/Oilbird/run/.s.PGSQL.<port>` is
already close to it before a long user name is added.

`OILBIRD_HOME` relocates all three roots, which is how the tests and the
clean-machine gate run against a container of their own.

## Enforcement

*A rule nobody can check is an opinion.* Every rule above states its
mechanism.

| rule | held by |
|---|---|
| `Model` imports nothing | the compiler — the target declares no dependency |
| A target imports only modules it declares | the compiler, with `--explicit-target-dependency-import-check error` |
| No library target imports AppKit | the `targets` check — **not the compiler** |
| The domain matrix | the `domains` check |
| No path literal outside `Paths` | the `paths` check |
| No logic hiding in an executable target | the `targets` check, rule `K-2` |
| No `Process` constructed outside `Child` | review |

Every check runs from `make lint`, as `swift run oilbird-checks`.
[CONTRIBUTING.md](CONTRIBUTING.md) lists all of them.

`Process()` is a Foundation type no domain owns, so the matrix cannot see
it being constructed. The `Child` rule is held by review, and the table
says so because that is what is true.

### The AppKit boundary is not compiler-enforced

A SwiftPM library target with Swift 6 language mode and `import AppKit`
builds clean and exits 0: AppKit is in the macOS SDK and SwiftPM imposes
no barrier on a library target. The `targets` check is the actual gate.
It reads every library target for `import AppKit|SwiftUI|UIKit|Cocoa|WebKit`,
and it proves it can detect one before it reports clean.

### How the matrix is checked

The domains inside `OilbirdCore` are one module, so there are no
imports between them. The boundary is checked by **symbol reference**:
`Fetch.` appearing in `Paths.swift` is a violation exactly as an import
would be in a multi-module layout. Two rules carry most of the value:

- **`DM-0`** — every source file is in a domain *and every one was
  read*. An unreadable file is a finding, not a skip: a checker that
  dies on its input is indistinguishable from a green one at the exit
  code alone. Add a file, add it to `domains.yaml`.
- **`DM-6`** — for each forbidden cell the check synthesises a violating
  reference and asserts a violation comes back. **A cell that cannot be
  made to fail is itself a finding.** This runs first on every
  invocation.

Carve-outs live in `domains.yaml` and nowhere else: `file` (never a
glob), `cell`, `because`, `retires_on`. An expired carve-out fails the
build, and a carve-out that matched nothing is stale.

## One owner of the cluster

Three clients over one core makes **concurrency the default, not the
exception**: a GUI, a CLI invocation and a long-lived MCP server can
all be live at once. Two Oilbirds running `initdb` on one data
directory, or two `postgres` on one cluster, is silent corruption.

Exactly one process owns the cluster, held by **two** mechanisms:

1. A lock file beside the data directory, created `O_CREAT|O_EXCL` so
   creation is atomic, carrying `{pid, host, started, argv}`.
2. An in-process owner.

Two, not one — because a second attempt *within the same process*
finds a lock file naming its own live PID, concludes it is the holder,
and opens the cluster twice.

## Four public surfaces

A published surface is a compatibility commitment. Oilbird has four:

1. Exported Swift symbols — the `OilbirdKit` barrel.
2. The CLI's verbs and flags.
3. The MCP tool schemas.
4. The on-disk container layout, which is a migration contract the
   moment a user has an installation.

The `parity` check holds the second and third against each other: every
MCP tool has a CLI verb, and every verb is in `--help`.

## Deliberately not here

- **Versioned entities, lineage, fork or pin.** An installation is
  present at a version or absent.
- **A selector grammar or query language.** Oilbird's CLI is verbs on a
  container.
- **Writing to SonarQube's data.** Oilbird owns the container and never
  its contents. It never writes to SonarQube's database directly — HTTP
  API or not at all.
