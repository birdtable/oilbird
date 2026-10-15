# Oilbird. Swift 6.x from Apple's Command Line Tools is the whole toolchain;
# swift-format ships inside it. Nothing here may require Node, npm, a Python
# package or a Homebrew formula.

SHELL := /bin/bash
.DEFAULT_GOAL := help

help:
	@echo "build   compile everything, warnings as errors"
	@echo "test    run the suites — must end 'N assertions, 0 failed'"
	@echo "fmt     format in place"
	@echo "lint    swift-format --strict, then every gate in oilbird-checks"
	@echo "swiftlint  a second opinion, behind a baseline; not part of lint"
	@echo "screenshots  recapture the README pictures (PROJECT=<key>)"
	@echo "gate    the clean-machine gate at L1, self-test only"
	@echo "coverage  how far the suite reaches (floored in coverage-budget.txt)"
	@echo "tsan    the suite under Thread Sanitizer"
	@echo "faults  the fault-injection self-test"
	@echo "app     build dist/Oilbird.app"
	@echo "install-app  copy it to ~/Applications"
	@echo "dist    package the bundle for release, with its SHA-256"

# ⚠ Two flags, both of which the build passes today and neither of which it
# passed by accident.
#
# `-warnings-as-errors`: a clean build printed three warnings and an
# incremental one printed none of them, so they had sat there since they
# landed — a discarded `try?`, a binding nobody read, and an API deprecated
# in 10.14. A warning nobody sees is a warning nobody fixes.
#
# `--explicit-target-dependency-import-check error`: a target that imports a
# module it does not declare stops compiling. The `domains` and `targets`
# gates already hold that rule by reading the source as text; this is the
# compiler holding the same rule, and the two disagreeing would be worth
# knowing about. Both are what swift-nio passes on every pull request.
STRICT := -Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error

build:
	swift build $(STRICT)

# ⚠ `swift build` first, and it is not redundant. `swift run oilbird-tests`
# builds the test target and its library dependencies — NOT the sibling
# `oilbird` executable. The idle suite spawns that binary as a real watchdog,
# so without this it tests whatever was built last.
test:
	@swift build -q $(STRICT)
	@swift run -q oilbird-tests

# How far the suite reaches, measured rather than assumed.
#
# `swift test` cannot run here -- neither XCTest nor swift-testing is
# importable with the Command Line Tools -- but coverage does not need it.
# Coverage is a compiler flag and two LLVM tools, and both tools ship IN the
# Command Line Tools:
#
#   /Library/Developer/CommandLineTools/usr/bin/llvm-profdata
#   /Library/Developer/CommandLineTools/usr/bin/llvm-cov
#
# So the suite is built instrumented, run, and the profile merged by hand.
# `--summary-only` because the full export is 10 MB of region data and the
# gate wants per-file line counts.
#
# ⚠ Its own build directory. Instrumented objects are not the ones `make
# test` and `make app` want, and sharing .build means every other target
# rebuilds behind this one.
COVDIR   := build/coverage
COVBIN   := $(COVDIR)/bin
COVFLAGS := -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping

# ⚠ Measuring and judging are separate targets, so `coverage-budget` can
# re-record at the moment the gate has just failed, which is when you want to.
coverage-measure:
	@rm -rf "$(COVDIR)" && mkdir -p "$(COVDIR)"
	@# Everything, not just the suite: six tests resolve `oilbird` BESIDE the
	@# test runner and fail with "no oilbird binary" when only the runner is
	@# built. The CLI is instrumented too, so what a test drives through a
	@# subprocess counts as reached, which it is.
	@swift build -q --scratch-path "$(COVBIN)" $(COVFLAGS)
	@# ⚠ To a FILE, then read back. `--show-bin-path` does not build, but it
	@# does resolve, and on a cold scratch path it prints "Fetching …" lines
	@# onto stdout, which land inside a command substitution and make the
	@# path a paragraph. Reading it through a pipe traded that for an
	@# intermittent SIGPIPE (`Error 141`); a file has neither failure.
	@set -e; \
	  swift build --scratch-path "$(COVBIN)" $(COVFLAGS) --show-bin-path \
	    > "$(COVDIR)/bin-path" 2>/dev/null; \
	  bin="$$(tail -1 "$(COVDIR)/bin-path")"; \
	  LLVM_PROFILE_FILE="$(COVDIR)/oilbird-%p.profraw" "$$bin/oilbird-tests"; \
	  xcrun llvm-profdata merge -sparse "$(COVDIR)"/*.profraw -o "$(COVDIR)/oilbird.profdata"; \
	  xcrun llvm-cov export "$$bin/oilbird-tests" \
	    -instr-profile "$(COVDIR)/oilbird.profdata" -summary-only \
	    -ignore-filename-regex='(\.build|/Tests/|/checkouts/)' > "$(COVDIR)/summary.json"

coverage: coverage-measure
	@swift run -q oilbird-checks coverage

coverage-budget: coverage-measure
	@swift run -q oilbird-checks coverage-budget > coverage-budget.txt
	@echo "re-recorded coverage-budget.txt"

# Data races, at run time, where the compiler was taking our word for it.
#
# ⚠ Swift 6 language mode removes most of these at compile time — but not the
# ones behind `@unchecked Sendable`, which is a promise the compiler accepts
# and never checks. This repository makes that promise in several places, and
# this is the only thing that reads it.
#
# Its own scratch path for the same reason coverage has one: sanitizer objects
# are not the ones `make test` and `make app` want.
#
# ⚠ `halt_on_error=0` so one race does not hide the rest. TSan reports and the
# suite keeps going; the grep below is what fails the target, because TSan
# itself exits 0 in that mode.
TSANDIR := build/tsan

tsan:
	@rm -rf "$(TSANDIR)" && mkdir -p "$(TSANDIR)"
	@swift build -q --scratch-path "$(TSANDIR)/bin" --sanitize=thread
	@# The same `--show-bin-path` hazard as `coverage-measure`: stderr
	@# dropped, last line taken.
	@swift build --scratch-path "$(TSANDIR)/bin" --sanitize=thread --show-bin-path \
	  > "$(TSANDIR)/bin-path" 2>/dev/null; \
	  bin="$$(tail -1 "$(TSANDIR)/bin-path")"; \
	  TSAN_OPTIONS=halt_on_error=0 "$$bin/oilbird-tests" > "$(TSANDIR)/run.log" 2>&1; \
	  echo "tsan: suite exited $$?"
	@races=$$(grep -c "WARNING: ThreadSanitizer" "$(TSANDIR)/run.log" || true); \
	  tail -3 "$(TSANDIR)/run.log"; \
	  if [ "$$races" -ne 0 ]; then \
	    echo "tsan: $$races data race(s) — see $(TSANDIR)/run.log"; \
	    grep -A8 "WARNING: ThreadSanitizer" "$(TSANDIR)/run.log" | head -40; \
	    exit 1; \
	  fi; \
	  echo "tsan: 0 data races over the whole suite"


# Regenerate the token vocabulary from the installed, pinned SonarQube.
# Run this whenever the manifest's SonarQube version changes; the suite fails
# until you do, which is the point.
tint-tokens:
	@printf '# Design tokens defined by SonarQube %s.\n' "$$(grep -A6 '\"sonarqube\"' Sources/OilbirdCore/Resources/manifest.json | grep '\"version\"' | head -1 | sed 's/.*: *\"//; s/\".*//')" > Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@printf '# Generated by `make tint-tokens` from the pinned server\047s own stylesheets.\n' >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@printf '# The tint fails safely to stock when a name is wrong, which is exactly why\n' >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@printf '# a wrong name is invisible - this list is what makes it a red test instead.\n' >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@printf '# min-viewport %s\n' "$$(cat "$$HOME/Library/Caches/Oilbird/sonarqube/web/css/"*.css | grep -oE '\.sw-container\{max-width:[0-9]+px' | grep -oE '[0-9]+' | sort -n -u | head -1)" >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@# Both palettes' grounds and text, so a SonarQube restyle turns
	@# the `chrome` gate red instead of leaving Oilbird's frame the wrong
	@# colour beside a dashboard that moved. Not folded into the grep above:
	@# these live inside two theme blocks in minified CSS, and telling which
	@# block a declaration is in is not something a line-oriented grep can do.
	@swift run -q oilbird-checks theme-values "$$HOME/Library/Caches/Oilbird/sonarqube/web/css" >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@cat "$$HOME/Library/Caches/Oilbird/sonarqube/web/css/"*.css | grep -oE -- '--echoes-[a-z0-9-]+:' | sed 's/:$$//' | sort -u >> Sources/OilbirdCore/Resources/sonarqube-tokens.txt
	@echo "tint-tokens: $$(grep -c -- '--echoes' Sources/OilbirdCore/Resources/sonarqube-tokens.txt) tokens"

fmt:
	swift format --in-place --recursive Sources Tests

# --strict is load-bearing: without it findings print as warnings and the exit
# code is 0, so the gate silently passes.
# ⚠ Builds first, and that is not redundant either. The `screens` gate draws
# the real binary on a real pseudo-terminal — it is the only gate that can see
# an overflow that exists only where there is a width — and against a stale
# binary it would pass on a screen nobody has.
#
# The gates are one Swift command, so the Command Line Tools stay the whole
# toolchain.
lint:
	@swift build -q
	@swift format lint --strict --recursive Sources Tests
	@swift run -q oilbird-checks

# SwiftLint, on purpose and not on every build. It is a COMMAND plugin, so
# `swift build` never runs it and a clean checkout never compiles it.
#
# ⚠ `TOOLCHAIN_DIR`, and without it this crashes rather than fails.
# SourceKitten dlopens `sourcekitdInProc.framework` and its search list is
# built for a full Xcode: it tries `Toolchains/XcodeDefault.xctoolchain/...`
# under whatever `xcode-select -p` says, which on Command Line Tools alone is
# a path that does not exist. The framework IS there, one directory up, at
# `usr/lib`. One variable points at it. The Command Line Tools are the whole
# toolchain, and this is what that costs.
#
# ⚠ Behind a baseline of one row: `dispatch`, where the arm count IS the
# verb count -- `.swiftlint.yml` carries the reasoning beside the threshold.
# A NEW finding is the only thing that prints, and `make swiftlint-baseline`
# re-records deliberately.
SWIFTLINT_TOOLCHAIN := TOOLCHAIN_DIR=/Library/Developer/CommandLineTools

swiftlint:
	@$(SWIFTLINT_TOOLCHAIN) swift package plugin --allow-writing-to-package-directory \
	  swiftlint lint --strict --baseline .swiftlint-baseline.json --quiet

# The README's pictures, captured from the binary on a real pseudo-terminal
# rather than drawn by hand, so a screen that changes and a README that does
# not is a state `git status` can notice.
#
# PROJECT names a scanned project, because `summary` and `issues` have nothing
# to draw without one. `docs/sample` is three small JavaScript files with real
# defects in them, kept for exactly this: scan it first, and the key it prints
# is what to pass here. The key carries a hash of the path, so it differs per
# machine and cannot be written down.
#
#     oilbird scan docs/sample
#     make screenshots PROJECT=sample-xxxxxxxx
#
# Run this on a machine with no scans of private projects: `scans` lists
# every project scanned.
PROJECT ?=

screenshots: build
	@swift run -q oilbird-checks screenshot help    88 --help
	@swift run -q oilbird-checks screenshot status  88 status
	@swift run -q oilbird-checks screenshot version 88 version
	@swift run -q oilbird-checks screenshot doctor  88 doctor
	@swift run -q oilbird-checks screenshot scans   88 scans
	@swift run -q oilbird-checks screenshot api     88 api
	@swift run -q oilbird-checks screenshot api-call 88 api projects/create
	@if [ -z "$(PROJECT)" ]; then \
	  echo "screenshots: summary and issues need PROJECT=<key>; run \`oilbird projects\`"; \
	else \
	  swift run -q oilbird-checks screenshot summary 88 summary "$(PROJECT)"; \
	  swift run -q oilbird-checks screenshot issues  88 issues  "$(PROJECT)"; \
	fi

# Re-records what the commenting standard is owed. The standard says do not
# sweep, so the debt is written down and ratcheted rather than paid at once.
comments-budget:
	@swift run -q oilbird-checks comments-budget > comments-budget.txt
	@echo "re-recorded comments-budget.txt"

swiftlint-baseline:
	@$(SWIFTLINT_TOOLCHAIN) swift package plugin --allow-writing-to-package-directory \
	  swiftlint lint --write-baseline .swiftlint-baseline.json --quiet
	@echo "re-recorded .swiftlint-baseline.json"

gate:
	@./scripts/clean-machine-gate.sh L1 --self-test

faults:
	@./scripts/fault-injection.sh --self-test

APP     := dist/Oilbird.app
BINARY  := .build/release/OilbirdApp

release:
	swift build -c release $(STRICT)

# The binary draws its own icon, so the bundle and the running app can never
# show different marks.
icon: release
	@rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	@$(BINARY) --write-icon build/icon-1024.png
	@printf '%s\n' "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
	  "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
	  "512 icon_512x512" "1024 icon_512x512@2x" | while read -r size name; do \
	    sips -z $$size $$size build/icon-1024.png --out "build/AppIcon.iconset/$$name.png" >/dev/null; \
	  done
	@iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "icon rendered"

app: release icon
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers" "$(APP)/Contents/Resources"
	@cp "$(BINARY)" "$(APP)/Contents/MacOS/Oilbird"
	@# The CLI CANNOT live in Contents/MacOS: macOS is case-insensitive, so
	@# `oilbird` and `Oilbird` are one file there and the CLI silently
	@# overwrote the app. Contents/Helpers is the convention for auxiliary
	@# executables and has no such clash.
	@cp .build/release/oilbird "$(APP)/Contents/Helpers/oilbird"
	@cp .build/release/oilbird-mcp "$(APP)/Contents/Helpers/oilbird-mcp"
	@# ⚠ The files, flat, into Contents/Resources — the one place a signed
	@# .app may keep them; see `Bundled.swift` for why the SwiftPM bundle
	@# cannot simply be dropped in whole. Without them `Bundle.module` falls
	@# through to this checkout's `.build` path and the app launches only on
	@# the machine that built it. `manifest.json` is the pinned list of
	@# everything a first run downloads.
	@cp .build/release/Oilbird_OilbirdCore.bundle/manifest.json \
		.build/release/Oilbird_OilbirdCore.bundle/sonarqube-tokens.txt \
		"$(APP)/Contents/Resources/"
	@# No `|| true` anywhere above, and checked besides. A resource bundle
	@# that fails to copy must fail the build: it cannot fail at launch, on
	@# a machine we do not have.
	@test -f "$(APP)/Contents/Resources/manifest.json" \
		|| { echo "app: manifest.json missing from the bundled resources"; exit 1; }
	@test -f "$(APP)/Contents/Resources/sonarqube-tokens.txt" \
		|| { echo "app: sonarqube-tokens.txt missing from the bundled resources"; exit 1; }
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@# The commit this bundle came from, stamped rather than tracked: the
	@# version string is 0.1.0 in every build, so a bug report saying
	@# "Oilbird 0.1.0" could not name what it measured.
	@/usr/libexec/PlistBuddy -c "Add :OilbirdBuild string $$(git rev-parse --short HEAD)$$(git diff --quiet HEAD 2>/dev/null || echo -dirty)" "$(APP)/Contents/Info.plist" >/dev/null
	@# Ad-hoc signed with a STABLE identifier. Without one macOS treats every
	@# build as a different app and drops any grant on each install.
	@codesign --force --sign - --identifier com.birdtable.oilbird "$(APP)" 2>/dev/null
	@touch "$(APP)"
	@echo "built $(APP)"

install-app: app
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(HOME)/Applications/Oilbird.app"
	@cp -R "$(APP)" "$(HOME)/Applications/Oilbird.app"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(HOME)/Applications/Oilbird.app"
	@echo "installed to ~/Applications/Oilbird.app"

# The one file a person downloads, and the digest they check it against.
#
# `ditto` rather than `zip`: it carries everything a `.app` MAY hold, so this
# stays correct on the day the bundle stops being flat.
#
# What is not assumed is the result. The zip is unpacked again and the
# unpacked copy verified, because "it packaged without erroring" is not the
# claim — nothing is present until it is verified — and it is the one
# machine with no other copy that pays.
#
# ⚠ And the digest, because Oilbird pins every one of the four artifacts it
# downloads by SHA-256 and will not install one that does not match. Shipping
# its own build with nothing to check it against would be asking of everyone
# else what it refuses to do itself.
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP     = dist/Oilbird-$(VERSION).zip

dist: app
	@# The same question `app` asks when it stamps `OilbirdBuild`, so the
	@# check and the stamp cannot disagree: an artifact stamped `-dirty`
	@# names a tree nobody can check out.
	@git diff --quiet HEAD 2>/dev/null 	  || { echo "dist: the tree is dirty — the bundle would be stamped -dirty"; exit 1; }
	@rm -f "$(ZIP)" "$(ZIP).sha256"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@rm -rf build/dist-check && mkdir -p build/dist-check
	@ditto -x -k "$(ZIP)" build/dist-check
	@codesign --verify --deep --strict build/dist-check/Oilbird.app 	  || { echo "dist: the packaged bundle does not verify after unpacking"; exit 1; }
	@rm -rf build/dist-check
	@cd dist && shasum -a 256 "Oilbird-$(VERSION).zip" > "Oilbird-$(VERSION).zip.sha256"
	@echo "built $(ZIP)  $$(du -h '$(ZIP)' | cut -f1)"
	@cat "$(ZIP).sha256"

.PHONY: help build test coverage coverage-measure coverage-budget tsan fmt lint swiftlint swiftlint-baseline comments-budget screenshots gate faults release icon app install-app dist
