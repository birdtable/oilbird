# Contributing to Oilbird

Oilbird downloads third-party software onto someone else's machine and
runs it there. That is the product, and it is why the rules below are
heavier than the size of the codebase suggests.

## The invariants

A reviewer holds every change against these. The ones a first patch is
most likely to trip:

- **No `PATH` assumptions.** No subprocess is ever launched by bare
  name. A GUI app launched from Finder inherits a minimal `PATH`, so a
  bare-name launch is a crash that never reproduces in a terminal.
- **The dependency triple.** Every managed dependency implements
  `detect() → install() → verify()`, and `verify()` runs the workload
  rather than stat-ing a file.
- **Never touch the user's dependencies.** Oilbird provisions its own
  JDK, PostgreSQL, SonarQube and scanner inside its own container. No
  Homebrew, no `/usr/local`, no adopting a cluster it did not create.
  The one exception is the opt-in command-line link in Settings, which
  puts `oilbird` itself into `/usr/local/bin`.
- **Localhost only.** Every listener binds `127.0.0.1`.
- **Downloads are verified.** Expected size and SHA-256, checked after
  transfer, failing closed.

Also forbidden outright: `try!` or force-unwrap on anything from the
filesystem, the network or a subprocess; blocking the main thread on
that I/O; a managed dependency's version string appearing anywhere but
`manifest.json`; treating a non-zero exit code as success.

If you believe an invariant is wrong, open an issue and argue for
changing it. A change that works around one will be sent back.

## Toolchain

Everything builds with the Xcode **Command Line Tools**. Full Xcode is
not required and is not used:

```
$ xcode-select -p
/Library/Developer/CommandLineTools
$ swift --version
Apple Swift version 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102)
```

**`swift test` does not work here, by design.** Neither XCTest nor
swift-testing ships with the Command Line Tools:

```
$ echo 'import XCTest' | swiftc -typecheck -
error: no such module 'XCTest'
$ echo 'import Testing' | swiftc -typecheck -
error: no such module 'Testing'
```

The suite is a hand-rolled harness compiled as an ordinary executable
target, `Tests/OilbirdKitTests`, and **you run it with `make test`.**
Do not replace it without first checking that the replacement still
runs on the Command Line Tools alone.

The same constraint binds the checks. Nothing invoked by `make lint` may
require Node, npm, a Python package or a Homebrew formula. The checks
are Swift, in the `OilbirdChecks` target, and `swift` is the only thing
`make lint` reaches for.

## Build, test, lint

`make help` prints the list; these are the real targets.

```
make build     swift build, warnings as errors
make test      the suite; must end "N assertions, 0 failed"
make fmt       swift format --in-place --recursive Sources Tests
make lint      swift format lint --strict, then every check in oilbird-checks
make coverage  how far the suite reaches, against coverage-budget.txt
make tsan      the suite under the thread sanitizer
make swiftlint a second opinion, behind a baseline; not part of lint
make gate      the clean-machine gate at L1, self-test only
make faults    which declared faults are injected, and which are not
```

`make build`, `make test` and `make release` all pass `-Xswiftc
-warnings-as-errors --explicit-target-dependency-import-check error`. The
first keeps warnings from sitting unread behind an incremental build. The
second stops a target importing a module it does not declare.

### `make swiftlint`

SwiftLint, run as a SwiftPM **command** plugin rather than a build-tool
plugin, so it never stands between a person and their compile errors.
It is not in `make lint`: swift-format owns layout, SwiftLint is asked
about what a formatter cannot see, and every rule swift-format already
holds is disabled in `.swiftlint.yml`. It runs with `--strict` and in CI.

`.swiftlint.yml` also carries a `custom_rules` entry for `Type(...)!`,
because SwiftLint's own `force_unwrapping` skips a `!` that follows a
closing paren.

The Makefile sets `TOOLCHAIN_DIR`, and it is not optional: SourceKitten
looks for `sourcekitdInProc.framework` where a full Xcode install keeps it,
and on the Command Line Tools alone SwiftLint crashes without it. If you
run the plugin by hand, set it too.

It runs behind `.swiftlint-baseline.json`, so only a NEW finding prints.
`make swiftlint-baseline` re-records it; doing that to silence something
you just wrote is how a baseline becomes a place to hide.

### Comments

A code commenting standard applies, and the `comments` check is its
instrument: five rules, described in full in
`Sources/OilbirdChecks/Comments.swift`.

The two that will catch you are `C-4` and `C-5`, and both are **ratchets
against `comments-budget.txt` rather than thresholds.** Comments are
rewritten when the code beneath them is touched, so the change is
reviewable in the same diff as the behaviour it describes; there is no
sweep. Every number in the budget is a debt. A file that gains an
over-cap block fails, and so does a file that loses one and keeps its
allowance, because an allowance for something that is no longer there is
an allowance for the next one.

**The cap is on inline `//` blocks and not on `///` doc comments.** For a
doc comment the interface is the right home: what `nil` means, what is
thrown, what is mutated, who owns the resource.

So when you touch a file: delete decoration and restatement, replace a
duplicated fact with a one-line citation, move anything with a home to its
home, keep what is local, non-obvious and homeless — then run `make
comments-budget` and commit a smaller number.

## What every change must pass

`make lint` and `make test`. Both, every time, before you send anything.

### `make lint` — swift-format, then fifteen checks

First `swift format lint --strict --recursive Sources Tests` against
`.swift-format` (110 columns, 4 spaces, `NeverUseForceTry`,
`UseEarlyExits`, and the rest). The `--strict` is load-bearing: without
it swift-format prints its findings as warnings and exits 0.

Then `swift run oilbird-checks`, cheapest first, running all of them and
exiting non-zero if any found something. `swift run oilbird-checks --list`
prints this table; `swift run oilbird-checks domains paths` runs two.

| check | the rule it holds |
|---|---|
| `domains` | the import matrix. `DM-0`: every file under `Sources/` belongs to a domain in `domains.yaml` and was actually read. `DM-1`: no domain references a domain it may not. `DM-4`: no grant to a domain that does not exist. `DM-6`: every forbidden cell is synthesised and asserted to fail |
| `targets` | `K-1`: no library target imports AppKit, SwiftUI, UIKit, Cocoa or WebKit. `K-2`: no file in an executable target is logic, which no test can reach |
| `paths` | no filesystem path literal outside `Sources/OilbirdCore/Paths.swift` |
| `calls` | no call whose cost the name does not say — `ProcessInfo.processInfo.hostName` blocks for 35 seconds |
| `prefs` | every property of `Preferences.Stored` has a coding key and is encoded |
| `settings` | no bare measurement in the settings window, no markdown in a string a user reads |
| `chrome` | Oilbird's dark ground is within 34/255 of SonarQube's, so the frame does not read as a border |
| `parity` | every MCP tool has a CLI verb, every menu row dispatches, every verb is in `--help` |
| `api` | the generic API surface names no endpoint, and every reserved path exists on the running server |
| `severities` | the severity words the code paints are exactly the ones the running server uses, read off `rules/search` rather than remembered |
| `overrides` | every control Oilbird hides is exactly where the override says it is, in the installed web app, and the SonarQube it was verified against is the one this build pins |
| `screens` | no screen overflows the terminal it is drawn on, and none names a colour instead of a role |
| `docs` | every image the README shows is on disk, and every captured image is shown. `make screenshots` draws the real binary on a real pseudo-terminal; this holds the wiring |
| `comments` | the commenting standard's five mechanised rules: no decoration, no commented-out code, a `TODO` says what makes it removable, inline `//` blocks capped at three lines, and emphasis not inflated |
| `coverage` | how far the suite reaches, floored per module and per file in `coverage-budget.txt`. `V-1` overall may not fall, `V-2` no module may fall, `V-3` the files no test enters are listed rather than counted, so a new one fails and one that gained coverage says to re-record |

Every check is made to fail on purpose before it may report clean: it
runs itself against a subject built to break its rule, and only if that
is caught does it look at the real one. That property is called **E5**,
and the gates print `(E5)` when they have shown it. The same holds for
the test harness, `make gate` and `make faults`.

Three exit codes, not two. `0` clean, `1` findings, and `2` the check
itself could not run — its subject changed shape, or it could not be made
to fail on purpose. A `2` is not a violation of the rule; it means nobody
knows whether the rule holds, which is worse and is why it is separate.

`api`, `severities`, `overrides`, `screens` and `coverage` read something
outside the repository — a built binary, a running engine, an installed web
app, an `llvm-cov` export — and say **NOT CHECKED** and pass when it is
absent. CI has no install step and must never have one, so on a hosted
runner they say so in the log rather than failing or reporting clean over
a subject they never read.

`overrides` has one arm that runs everywhere, and it is the one that
matters after a version bump. `Tint.overridesVerifiedAgainst` names the
SonarQube the overrides were last checked against; the check compares it
to the version `manifest.json` pins and fails the moment they differ. A
version bump therefore lands only after the check has run against the new
engine and that line has moved.

Two things surprise people here.

**Domains inside `OilbirdCore` are one module, so there are no imports
between them.** The boundary is checked by *symbol reference* instead:
`Fetch.` appearing in `Paths.swift` is a violation exactly as an import
would be in a multi-module layout. This is why the caseless-`enum`
namespace convention is load-bearing rather than stylistic.

**Adding a source file means editing `domains.yaml`.** A file in no
domain is a `DM-0` finding and fails the build, because a file no rule
ran against is indistinguishable from a clean one at the exit code
alone. Put it in a domain, and give that domain a `may_reference` row it
can actually live within. Carve-outs live in `domains.yaml` and nowhere
else, are named by `file` and never by glob, and carry a `because` and a
`retires_on`.

### `make coverage` and `make tsan`

Coverage is a compiler flag and two LLVM tools, and both tools ship
inside the Command Line Tools. `make coverage` builds the package
instrumented into `build/coverage`, runs the suite, merges the profile and
exports a per-file summary that the `coverage` check reads.

It builds everything, not just the suite. Some tests run the `oilbird`
binary beside the runner, and instrumenting the CLI too means what a test
drives through a subprocess counts as reached.

Each figure in `coverage-budget.txt` is recorded one tenth of a percent
under what was measured, because the suite drives timed subprocess paths
and two runs of one commit can differ by a line. `make coverage-budget`
re-records, and deliberately does not depend on `make coverage`, so it
still runs when the gate has just failed.

`make tsan` builds with `--sanitize=thread` into `build/tsan` and runs the
whole suite. Swift 6 language mode removes most data races at compile
time, but not the ones behind `@unchecked Sendable`, which is a promise
the compiler accepts and never checks.

### `make test` — and the zero-assertion rule

The last line must read `N assertions, 0 failed`, and the command must
exit 0.

**A test that asserts nothing FAILS.** The harness counts assertions
before and after each test body, and a body that added none is recorded
as a failure. A test whose assertions all sit inside a loop over an empty
collection is worse than no test at all, because it reports coverage that
does not exist.

The harness also proves it can fail before it runs anything — it feeds
itself a wrong assertion and checks that the failure registers. A gate
that has never failed is not known to work; the same rule applies to
gates you add.

The suite has no discovery: `Tests/OilbirdKitTests/main.swift` is a
hand-written registry. Register a new suite there.

### Continuous integration

`.github/workflows/ci.yml` runs three jobs in parallel on every push and
every pull request. `L1` is `swift build`, `make test`, `make coverage`,
`make lint`, `make gate`, `make faults` and `make swiftlint`. Beside it,
**Thread Sanitizer** runs the suite again under `--sanitize=thread`, and
**Supply chain** runs OSV-Scanner over `Package.resolved`.

The two beside `L1` are separate so that `L1` stays the evidence that the
build and the gates need nothing fetched or configured beyond a checkout.
There is no install step in `L1` and there must never be one: no Homebrew,
no npm, no pip, no toolchain action that fetches a Swift.

CI has two limits. A hosted macOS runner ships a full Xcode and cannot
uninstall it, so CI does not prove that Oilbird builds with the Command
Line Tools alone. And CI runs `L1` only; `L2` and `L3` need a second user
account and a real VM.

The suite runs twice in `L1`: `make test` in the configuration that ships,
as the assertion gate, and `make coverage` instrumented, as the
measurement. CI also parses `make test`'s summary line rather than
trusting its exit code, and fails a run that reports `0 assertions`.

### `make gate` and `make faults`

`make gate` runs `scripts/clean-machine-gate.sh L1 --self-test`: the
`L1` layer with `PATH` cut to `/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`
relocated, and `JAVA_HOME` unset. The `L2` and `L3` runners are not
automated; the script exits 2 for both, naming the throwaway user account
and the fresh VM each would need.

| layer | what it isolates | when |
|---|---|---|
| `L1` | inherited `PATH`, an existing container, ambient `JAVA_HOME` | every commit |
| `L2` | a fresh macOS user account — Homebrew on `PATH`, user-level state | before merge, by hand |
| `L3` | a fresh macOS VM — anything system-wide, Gatekeeper | before release, by hand |

`make faults` runs `scripts/fault-injection.sh --self-test` over the
declared failure modes — offline, a stalled or truncated download, a
corrupt or wrong-length artifact, a full disk, quarantine, stale and
recycled PIDs, a half-initialised cluster, a server that never becomes
healthy, a decoy on the port — and reports which test injects each. A
declared failure mode nothing exercises is a different thing from a
handled one, and the script refuses to imply coverage it does not have.

Both prove they can fail before they pass, and both must stay that way.

## Pull requests

A pull request says what it changes and how a reviewer can check it:

- **A command that passes or fails.** At least one thing a reviewer can
  run. "Verified manually" is not a definition of done. Say which layer
  it ran at.
- **What it means on a clean machine.** A Mac with no JDK, no
  PostgreSQL, no SonarQube and no scanner. If the answer is "nothing",
  say so. Evidence gathered on a machine that already had the dependency
  installed is not evidence.

A small change with no design implication can go straight to a pull
request. Anything touching provisioning should start as an issue.

Open an issue before writing code if:

- a managed dependency's licence forbids automated download, or its
  terms are ambiguous;
- a download source has no stable URL or no publishable checksum;
- the simplest path would touch a dependency the user already has —
  including reusing their PostgreSQL;
- a change cannot be made without breaking one of the invariants above.

"This does not work", reported early, is worth more than a workaround
discovered at review.

## Commits

- The subject line is an imperative summary.
- The body says what changed, why, and what evidence supports it,
  naming the gate and its result.
- Co-authorship trailers are required where an agent produced the work.

Never:

- force-push `main`;
- rebase a branch someone else is working on;
- `--no-verify`;
- amend a pushed commit;
- commit a real email address — use the GitHub `noreply` address;
- commit anything from the container: `credentials.json`, tokens,
  cluster data. They live outside the repository by design and must stay
  there.

## Licence

**GNU General Public License v3.0.** See [`LICENSE`](LICENSE). By
sending a patch you agree it is contributed under those terms.

Oilbird does not redistribute the software it installs — it downloads
SonarQube, a JDK, PostgreSQL and the scanner at run time from their own
origins. Their licences are recorded in [`NOTICE`](NOTICE) and none of
them propagates into this repository, because none of it ships here.

## Security

Do not report a vulnerability through a pull request or a public issue.
See [`SECURITY.md`](SECURITY.md).
