#!/usr/bin/env bash
# The clean-machine gate. On a Mac with no JDK, no PostgreSQL, no SonarQube
# and no scanner, Oilbird must still get from nothing to a scanned project
# without the user installing anything by hand. A developer's machine, which
# has everything installed, is the one place that cannot be observed, so the
# gate takes it away in three layers, each catching what the cheaper one
# cannot:
#
#   L1  a sandboxed environment: cut PATH, cleared environment, a throwaway
#       container. Seconds; every commit.
#   L2  a throwaway macOS user account. Minutes; before merge.
#   L3  Gatekeeper on a quarantined bundle, in a fresh VM or `--local`.
#       Before release.
#
# Exit codes are the harness's own, deliberately NOT the CLI's:
#   0 pass · 1 a check failed · 2 could not run · 3 skipped (CLI not built)
# The 2/1 split matters most: a gate that died must never read as a clean one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYER=""; UNTIL="scan"; SELF_TEST=0; ONLY=""
# Declared with the other defaults, before the argument parser sets it.
L3_LOCAL=0

die()  { echo "gate: $*" >&2; exit 2; }
fail() { echo "gate: FAIL — $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    L1|L2|L3)     LAYER="$1"; shift ;;
    --until)      UNTIL="${2:-}"; shift 2 ;;
    --only)       ONLY="${2:-}"; shift 2 ;;
    --self-test)  SELF_TEST=1; shift ;;
    --local)      L3_LOCAL=1; shift ;;
    *)            die "unknown argument '$1'" ;;
  esac
done
[ -n "$LAYER" ] || die "name a layer: L1, L2 or L3"
case "$UNTIL" in doctor-before|doctor|install|up|scan) ;; *) die "unknown phase '$UNTIL'" ;; esac

# The cache MUST NOT live under ~ : L1 relocates HOME, so a ~-derived cache is
# cold on every run and the layer that runs on every commit would re-download
# 1.14 GiB forever without ever erroring.
: "${OILBIRD_TEST_CACHE:=/private/tmp/oilbird-test-artifacts}"
export OILBIRD_TEST_CACHE
mkdir -p "$OILBIRD_TEST_CACHE" || die "cannot create $OILBIRD_TEST_CACHE"

# --- the gate must be provably able to fail (E5) -----------------------------
self_test() {
  local sandbox rc
  sandbox="$(mktemp -d)"
  # A binary that is present but does not run is not present — nothing is
  # until it verifies — and that is exactly what the gate must catch.
  printf '#!/bin/sh\nexit 9\n' > "$sandbox/oilbird"; chmod +x "$sandbox/oilbird"
  ( CLI="$sandbox/oilbird" run_phase doctor ) >/dev/null 2>&1; rc=$?
  rm -rf "$sandbox"
  [ "$rc" -eq 1 ] || { echo "gate: SELF-TEST FAILED — a broken CLI did not fail the gate (rc=$rc)" >&2; exit 2; }

  # ⚠ And that the sandbox is APPLIED. A gate whose isolation is a function
  # nobody calls reports the absence of a test.
  local seen_home seen_container seen_path
  seen_home="$(sandbox_env sh -c 'printf %s "$HOME"')"
  seen_container="$(sandbox_env sh -c 'printf %s "$OILBIRD_HOME"')"
  seen_path="$(sandbox_env sh -c 'printf %s "$PATH"')"
  [ "$seen_container" = "$SANDBOX" ] || {
    echo "gate: SELF-TEST FAILED — OILBIRD_HOME is '$seen_container', not the sandbox" >&2; exit 2; }
  [ "$seen_home" = "$SANDBOX" ] || {
    echo "gate: SELF-TEST FAILED — HOME escaped the sandbox" >&2; exit 2; }
  [ "$seen_path" = "/usr/bin:/bin:/usr/sbin:/sbin" ] || {
    echo "gate: SELF-TEST FAILED — PATH was inherited: $seen_path" >&2; exit 2; }
  # The negative: the caller's own environment must NOT reach a phase.
  JAVA_HOME=/nope PGDATA=/nope sandbox_env sh -c '[ -z "$JAVA_HOME" ] && [ -z "$PGDATA" ]' || {
    echo "gate: SELF-TEST FAILED — an ambient JAVA_HOME or PGDATA survived" >&2; exit 2; }
  echo "gate: sandbox verified — OILBIRD_HOME=$SANDBOX, PATH cut, environment cleared"

  # ⚠ L2's claim is a DIFFERENT one and needs its own arm: that the phases run
  # as somebody else. `HOME` can be faked and `OILBIRD_HOME` can be overridden,
  # but `id -u` cannot, which is exactly why L2 catches what L1 cannot.
  if [ "${LAYER:-L1}" = "L2" ]; then
    local ran_as mine
    ran_as="$(l2_env id -un 2>/dev/null || echo "")"
    mine="$(id -un)"
    [ "$ran_as" = "$L2_USER" ] || {
      echo "gate: SELF-TEST FAILED — phases ran as '$ran_as', not '$L2_USER'" >&2; exit 2; }
    [ "$ran_as" != "$mine" ] || {
      echo "gate: SELF-TEST FAILED — the throwaway account is the current user" >&2; exit 2; }
    l2_env test -d "/Users/$L2_USER/Library/Application Support/Oilbird" && {
      echo "gate: SELF-TEST FAILED — the fresh account already has a container" >&2; exit 2; }
    echo "gate: account verified — phases run as $ran_as, not $mine, with no container"
  fi

  echo "gate: self-test passed — it has been made to fail on purpose (E5)"
}

# The gate interprets the CLI's exit codes rather than passing them through,
# and what counts as success is PHASE-SPECIFIC. On a clean machine `doctor`
# reporting every dependency missing is the expected first result, not a
# failure -- a gate that treated 3 as failure everywhere could never run step
# one of the sequence it exists to run.
# Which environment a phase runs in, and with which copy of the CLI. `self_test`
# overrides CLI and stays on the L1 path, which is the one it is asserting about.
phase_env() {
  if [ "${LAYER:-L1}" = "L2" ]; then l2_env "$@"; else sandbox_env "$@"; fi
}

phase_fixture() {
  if [ "${LAYER:-L1}" = "L2" ]; then echo "$L2_STAGE/sample"; else echo "$ROOT/docs/sample"; fi
}

phase_cli() {
  if [ "${LAYER:-L1}" = "L2" ]; then echo "$L2_STAGE/oilbird"
  else echo "${CLI:-$ROOT/.build/debug/oilbird}"; fi
}

run_phase() {
  local phase="$1" cli="${CLI:-$(phase_cli)}"
  [ -x "$cli" ] || return 3
  # ⚠ THROUGH the sandbox, or every phase runs with the caller's PATH,
  # JAVA_HOME and container.
  # `scan` takes a path and every other phase takes none.
  # `docs/sample` is three small JavaScript files this repository keeps with
  # defects left in on purpose, which is why the case below accepts exit 4.
  # ⚠ Branch rather than an array: macOS ships bash 3.2, where `"${a[@]}"` on
  # an EMPTY array is an unbound variable under `set -u`.
  if [ "$phase" = "scan" ]; then
    phase_env "$cli" scan "$(phase_fixture)" --json >/dev/null 2>&1
  else
    phase_env "$cli" "${phase%-before}" --json >/dev/null 2>&1
  fi
  local rc=$?
  case "$phase" in
    doctor-before)  [ "$rc" -eq 3 ] || return 1 ;;   # everything missing: correct
    doctor)         [ "$rc" -eq 0 ] || return 1 ;;   # everything present now
    # CLI 4 is "quality gate failed", which is a PASS for provisioning: the
    # fixture is allowed to have issues. What is tested is that a scan ran.
    scan)           [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || return 1 ;;
    *)              [ "$rc" -eq 0 ] || return 1 ;;
  esac
  return 0
}

# The throwaway container every phase reads and writes. One per run, so the
# sequence doctor-before → install → doctor → up → scan is a single machine's
# life rather than five unrelated ones.
: "${SANDBOX:=$(mktemp -d)}"

sandbox_env() {
  # L1: the environment a Finder-launched app actually gets, plus every PG*
  # cleared — absolute paths do not protect against an inherited PGDATA.
  #
  # ⚠ `OILBIRD_HOME`, not just `HOME`. `homeDirectoryForCurrentUser` reads
  # `getpwuid` and ignores the environment, so a gate that relocated only HOME
  # would install into the developer's real container and report success. That
  # is worse than no sandbox, because it looks like one.
  env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$SANDBOX" \
    OILBIRD_HOME="$SANDBOX" \
    OILBIRD_TEST_CACHE="$OILBIRD_TEST_CACHE" \
    TMPDIR="${TMPDIR:-/tmp}" \
    "$@"
}

# ── L2: a throwaway macOS user account ───────────────────────────────────────
#
# What L1 cannot reach. L1 relocates `OILBIRD_HOME` but still runs as the
# developer, so it shares their `getpwuid` home, their keychain, their launchd
# session and their file ownership. Homebrew also stays on disk at its absolute
# paths, so code hardcoding `/opt/homebrew/bin/...`
# passes L1 and should not pass L2.
#
# ⚠ L2 deliberately does NOT set `OILBIRD_HOME`. The isolation here is the
# ACCOUNT, and overriding the container would test the override instead of the
# thing — a fresh user's `~/Library/Application Support/Oilbird` genuinely does
# not exist, which is the condition a first-time user is in.
L2_USER="oilbird-gate"
L2_STAGE="/private/tmp/oilbird-l2-stage"

l2_setup() {
  sudo -n true 2>/dev/null || die \
    "L2 creates a throwaway account and needs sudo. Authenticate first: sudo -v"
  id "$L2_USER" >/dev/null 2>&1 && l2_remove

  echo "gate: creating the throwaway account '$L2_USER'"
  # A password nobody keeps: the account exists for one run and is deleted in
  # the trap. It is never typed and never stored.
  sudo sysadminctl -addUser "$L2_USER" -fullName "Oilbird clean-machine gate" \
    -password "$(uuidgen)" -home "/Users/$L2_USER" >/dev/null 2>&1 \
    || die "could not create $L2_USER"
  sudo mkdir -p "/Users/$L2_USER" && sudo chown "$L2_USER" "/Users/$L2_USER"

  # The account has no checkout, so what it runs is staged where anyone can
  # read it. `a+rX` and not `a+rx`: the capital X marks directories executable
  # without making every file so.
  rm -rf "$L2_STAGE"; mkdir -p "$L2_STAGE"
  cp "${CLI:-$ROOT/.build/debug/oilbird}" "$L2_STAGE/oilbird"
  cp -R "$ROOT/docs/sample" "$L2_STAGE/sample"
  chmod -R a+rX "$L2_STAGE"
  [ -d "$OILBIRD_TEST_CACHE" ] && chmod -R a+rX "$OILBIRD_TEST_CACHE"
  trap l2_remove EXIT

  # ⚠ L2 gets the cache too, or every run fetches 1.22 GB from origin. Seeded
  # as the account, because the files land in ITS container and must be owned
  # by it.
  local partials="/Users/$L2_USER/Library/Caches/Oilbird/partials"
  sudo -u "$L2_USER" mkdir -p "$partials" 2>/dev/null || true
  if [ -d "$OILBIRD_TEST_CACHE" ]; then
    local n=0
    for f in "$OILBIRD_TEST_CACHE"/*; do
      [ -f "$f" ] || continue
      # A copy, not a link: the cache is the developer's and the account is
      # about to be deleted with its home.
      sudo -u "$L2_USER" cp "$f" "$partials/" 2>/dev/null && n=$((n + 1))
    done
    [ "$n" -gt 0 ] && echo "gate: seeded $n artifact(s) into $L2_USER's container"
  fi
}

l2_remove() {
  local rc=$?
  # Stop anything the account started before the account goes, or its engine
  # outlives the user that owns it.
  sudo -u "$L2_USER" "$L2_STAGE/oilbird" down --force >/dev/null 2>&1 || true
  sudo sysadminctl -deleteUser "$L2_USER" >/dev/null 2>&1 || true
  sudo rm -rf "/Users/$L2_USER" >/dev/null 2>&1 || true
  rm -rf "$L2_STAGE"
  echo "gate: '$L2_USER' and its home are gone"
  return $rc
}

# As the throwaway user, with no profile read and no Homebrew on PATH.
l2_env() {
  sudo -u "$L2_USER" env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="/Users/$L2_USER" \
    OILBIRD_TEST_CACHE="$OILBIRD_TEST_CACHE" \
    TMPDIR=/tmp \
    "$@"
}

# ── L3: a fresh macOS VM, and Gatekeeper ─────────────────────────────────────
#
# The only layer that meets Gatekeeper on a bundle that ARRIVED rather than one
# that was built here. A locally built app carries no `com.apple.quarantine`,
# so neither L1 nor L2 can see the refusal a downloading user gets, and an L3
# that skipped the quarantine would pass for the wrong reason.
#
# ⚠ The quarantine flag is SET BY THIS SCRIPT rather than earned by a real
# download, and that is a stated simplification. What it buys is the honest
# direction: the flag only ever makes Gatekeeper stricter, so a bundle that is
# refused with it set would also be refused after a real download. A pass here
# would prove less than a failure does, which is why the result below is
# reported rather than asserted away.
L3_VM="${OILBIRD_L3_VM:-oilbird-l3}"
L3_IMAGE="${OILBIRD_L3_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
L3_IP=""
# Where the bundle being judged actually is: the VM's home, or a quarantined
# copy here under `--local`.
L3_APP="$HOME/Oilbird.app"

l3_setup() {
  [ -d "$ROOT/dist/Oilbird.app" ] || die "no dist/Oilbird.app — run \`make app\` first"

  # ⚠ `--local` is not a lesser L3 pretending to be L3. `spctl --assess` is a
  # POLICY evaluation of the bundle's signature and returns the same verdict on
  # any Mac, so the ANSWER does not need a VM. What the VM adds is the launch
  # experience — the dialog, its wording, the bypass a user has to find — and
  # that is about the machine, so `--local` does not claim it.
  if [ "$L3_LOCAL" -eq 1 ]; then
    rm -rf /tmp/oilbird-l3-local && mkdir -p /tmp/oilbird-l3-local
    cp -R "$ROOT/dist/Oilbird.app" /tmp/oilbird-l3-local/
    # A COPY, so the one in dist/ is left as the build left it.
    xattr -w com.apple.quarantine "0083;00000000;Safari;" /tmp/oilbird-l3-local/Oilbird.app
    L3_APP=/tmp/oilbird-l3-local/Oilbird.app
    trap 'rm -rf /tmp/oilbird-l3-local' EXIT
    echo "gate: assessing a quarantined copy here; no VM, so no launch dialog"
    return 0
  fi
  command -v tart >/dev/null 2>&1 || die "L3 needs tart to make a fresh VM"

  # ⚠ Cloned from the base image every run, never reused. A VM that has opened
  # this app before has already been told yes, and Gatekeeper remembers: the
  # second run of a reused VM would pass and mean nothing.
  tart list 2>/dev/null | grep -q " $L3_VM " && { tart delete "$L3_VM" >/dev/null 2>&1 || true; }
  echo "gate: cloning $L3_IMAGE into a fresh $L3_VM"
  tart clone "$L3_IMAGE" "$L3_VM" >/dev/null 2>&1 || die "could not clone $L3_IMAGE"
  trap l3_remove EXIT

  tart run "$L3_VM" --no-graphics >/dev/null 2>&1 &
  echo "gate: waiting for $L3_VM"
  local tries=0
  until L3_IP="$(tart ip "$L3_VM" 2>/dev/null)" && [ -n "$L3_IP" ]; do
    tries=$((tries + 1)); [ "$tries" -gt 60 ] && die "$L3_VM never took an address"
    sleep 5
  done
  # ⚠ Key auth, and it fails FAST rather than spinning. A stock
  # `macos-tahoe-base` has no key for anybody: it ships with a documented
  # default password, and a gate that types a password is a gate that has
  # learned to type passwords. Arrange a key once, in an image of your own.
  tries=0
  until ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "admin@$L3_IP" true 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 12 ] && die \
      "$L3_VM is up at $L3_IP but will not take a key. Build an image that
       trusts yours and point OILBIRD_L3_IMAGE at it; this gate does not
       type passwords."
    sleep 5
  done
  echo "gate: $L3_VM is up at $L3_IP"

  # Delivered as an archive and unpacked there, so the bundle arrives the way
  # one does rather than being written in place by the build.
  tar -C "$ROOT/dist" -czf "/tmp/Oilbird-l3.tgz" Oilbird.app
  scp -q -o StrictHostKeyChecking=no "/tmp/Oilbird-l3.tgz" "admin@$L3_IP:/tmp/" \
    || die "could not deliver the bundle"
  l3_sh 'cd ~ && rm -rf Oilbird.app && tar xzf /tmp/Oilbird-l3.tgz && \
         xattr -w com.apple.quarantine "0083;00000000;Safari;" ~/Oilbird.app' \
    || die "could not unpack or quarantine the bundle"
  rm -f "/tmp/Oilbird-l3.tgz"
}

l3_sh() {
  if [ "$L3_LOCAL" -eq 1 ]; then bash -c "$*"
  else ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$L3_IP" "$@"; fi
}

l3_remove() {
  local rc=$?
  tart stop "$L3_VM" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then
    tart delete "$L3_VM" >/dev/null 2>&1 || true
    echo "gate: $L3_VM deleted"
  else
    echo "gate: $L3_VM kept for inspection (tart run $L3_VM)" >&2
  fi
  return $rc
}

# ⚠ Oilbird is ad-hoc signed. So "the download is accepted" is not the bar —
# it never will be — and a gate that failed on it for ever would be a gate
# somebody turns off.
#
# The bar is the install path the README actually recommends: a bundle you
# BUILT is not quarantined and opens with a double click. That is assertable
# and it can fail: if `make app` ever started producing a quarantined bundle,
# or the refusal on a download turned into something worse than one visit to
# Settings, this says so.
#
# The download verdict is still measured and printed every run, because a
# decision to accept a cost is only honest while somebody can see the cost.
l3_gatekeeper() {
  local verdict built
  verdict="$(l3_sh "spctl --assess --type execute -vv '$L3_APP' 2>&1" || true)"
  echo "    downloaded: $(echo "$verdict" | head -1)"

  built="$(xattr -p com.apple.quarantine "$ROOT/dist/Oilbird.app" 2>/dev/null || true)"
  if [ -n "$built" ]; then
    echo "  ✗ gatekeeper — a bundle straight from \`make app\` is QUARANTINED"
    echo "    The README tells people to build it because that asks them nothing."
    echo "    If the build starts quarantining its own output, that stops being true."
    return 1
  fi
  echo "  ✓ gatekeeper — \`make app\` output is not quarantined; it opens on a double click"

  if echo "$verdict" | grep -q 'accepted'; then
    echo "    (and a download is accepted too, which means somebody signed it)"
  else
    echo "    A DOWNLOAD is refused, and that is the accepted cost of having no"
    echo "    Apple Developer certificate. One visit to System Settings ▸ Privacy"
    echo "    & Security ▸ Open Anyway, documented in the README."
  fi
  return 0
}

# The artifact cache, keyed by checksum and never by URL or version string, so
# a changed artifact under a fixed version is a miss. `Fetch` already names
# every partial after its SHA-256, so the cache is those files and nothing else
# is needed in the product. Hard links, so a 1.14 GiB seed costs no disk and a corrupted one
# cannot be shared back by accident — `Fetch` deletes rather than rewrites.
seed_cache() {
  local partials="${1:-$SANDBOX}/Library/Caches/Oilbird/partials"
  mkdir -p "$partials"
  [ -d "$OILBIRD_TEST_CACHE" ] || return 0
  local n=0
  for f in "$OILBIRD_TEST_CACHE"/*; do
    [ -f "$f" ] || continue
    ln -f "$f" "$partials/$(basename "$f")" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "gate: seeded $n artifact(s) from the cache"
  return 0
}

# ⚠ Shared back only after a run that VERIFIED them. `Fetch` discards a
# mismatch rather than caching it, so anything still here matched its digest.
save_cache() {
  local partials="$SANDBOX/Library/Caches/Oilbird/partials"
  [ -d "$partials" ] || return 0
  mkdir -p "$OILBIRD_TEST_CACHE"
  for f in "$partials"/*; do
    [ -f "$f" ] || continue
    [ -e "$OILBIRD_TEST_CACHE/$(basename "$f")" ] || ln -f "$f" "$OILBIRD_TEST_CACHE/" 2>/dev/null
  done
  return 0
}

# ⚠ The layer is set up BEFORE the self-test: L2's self-test arm asks the
# throwaway account who it is, and there is no account until `l2_setup` has
# made one. `l2_setup` arms its own trap, so the account is removed whichever
# way this exits.
case "$LAYER" in
  L1) ;;
  L2) l2_setup ;;
  L3) l3_setup ;;
esac

[ "$SELF_TEST" -eq 1 ] && { self_test; exit 0; }

echo "gate: layer $LAYER, until '$UNTIL'${ONLY:+, only $ONLY}"
case "${LAYER:-L1}" in
  L2) echo "gate: running as '$L2_USER', whose ~/Library has never seen Oilbird" ;;
  L3) if [ "$L3_LOCAL" -eq 1 ]; then
        echo "gate: judging the bundle, not the machine"
      else
        echo "gate: running on $L3_VM, a Mac that has never seen this bundle"
      fi ;;
  *)  echo "gate: container $SANDBOX" ;;
esac
[ "${LAYER:-L1}" = "L1" ] && seed_cache

# ⚠ The gate STARTS an engine: `up` is one of the five phases. Stopping it is
# part of the run, or each run leaves a PostgreSQL, two JVMs and a 3.6 GiB
# container behind.
#
# The container is kept when the gate fails, because that is when somebody
# needs to look inside it, and removed when it passes.
teardown() {
  local rc=$?
  save_cache
  sandbox_env "${CLI:-$ROOT/.build/debug/oilbird}" down --force >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then
    rm -rf "$SANDBOX"
  else
    echo "gate: container kept for inspection at $SANDBOX" >&2
  fi
  return $rc
}
[ "${LAYER:-L1}" = "L1" ] && trap teardown EXIT
# ⚠ L3 asks Gatekeeper FIRST and stops there for now. Everything after it —
# install, up, scan — is what L1 and L2 already prove, and on a bundle the
# system refuses to launch there is nothing after it to measure. If the bundle
# is ever signed and the answer flips to accepted, the rest of the sequence
# follows.
if [ "${LAYER:-L1}" = "L3" ]; then
  l3_gatekeeper || { echo "gate: FAIL at gatekeeper"; exit 1; }
  echo "gate: pass"
  exit 0
fi

skipped=0
for phase in doctor-before install doctor up scan; do
  run_phase "$phase"; rc=$?
  case $rc in
    0) echo "  ✓ $phase" ;;
    3) echo "  ⊘ $phase — skipped, CLI not built"; skipped=1 ;;
    *) fail "$phase" ;;
  esac
  [ "$phase" = "$UNTIL" ] && break
done

[ "$skipped" -eq 1 ] && { echo "gate: SKIPPED — no CLI to run; build it first"; exit 3; }
echo "gate: pass"
