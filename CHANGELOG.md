# Changelog

All notable changes to Oilbird are recorded here.

The format is based on [Keep a Changelog][kac], and this project
adheres to [Semantic Versioning][semver].

## [0.1.0] — 2026-10-15

The first public release. Pins SonarQube Community Build 26.10.0.133078.

### Added

- **Zero-precondition provisioning.** On first launch Oilbird downloads a
  Temurin JDK 21, PostgreSQL 16, SonarQube Community Build 26.10.0.133078 and
  SonarScanner CLI 7.3 from their official origins, 1.22 GB in all. Each is
  pinned by version, size and SHA-256 in `manifest.json`, verified before it is
  unpacked, installed atomically into Oilbird's own container under
  `~/Library`, and checked by running it rather than by looking for its files.
  Interrupted downloads resume.
- **A supervised engine.** Oilbird's own PostgreSQL cluster and SonarQube
  server, both bound to `127.0.0.1` on OS-assigned ports, owned by exactly one
  process at a time. The engine starts when a command needs it and stops after
  an idle interval you choose (thirty minutes by default, or never).
- **The app.** A menu-bar app whose window is SonarQube's own dashboard inside
  Oilbird's frame, with a first-run screen, a scan action, dark mode that tints
  SonarQube to match, and a Settings window with General, Engine, Scanning,
  Agents, Storage and Versions panes, including reclaiming disk space and
  opening at login.
- **The `oilbird` command line**, with twenty-two verbs: `doctor`, `scan`,
  `scans`, `follow`, `summary`, `issues`, `gate`, `history`, `projects`,
  `configure`, `forget`, `api`, `up`, `down`, `status` and more. Screens go
  to stderr and `--json` to stdout. Bare `oilbird` at a terminal offers a
  menu, and `oilbird issues <key> --browse` is a full-screen issue browser.
  Scans can be detached, listed, followed from any terminal and stopped.
- **`oilbird api`**, reaching every call the running server offers, read off
  the server itself, with parameters, legal values and a copyable command for
  each.
- **`oilbird-mcp`**, an MCP server inside the app with fifteen tools that
  behave exactly like their CLI verbs. The Agents pane in Settings writes the
  client configuration for your install.
- **Per-project configuration**: display name, tags, the new-code rule,
  exclusions and the branch name, each read back from the server before it is
  reported as saved.
- Plugins placed in SonarQube's `extensions/plugins` survive an upgrade of the
  pinned SonarQube.

[0.1.0]: https://github.com/birdtable/oilbird/releases/tag/v0.1.0
[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html
