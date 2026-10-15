#!/usr/bin/env bash
# Fault injection. No failure may leave the user without a way forward, which
# is only checkable if failures can be produced on demand.
#
# Fault slugs are declared once, in the matrix below. An unrecognised --faults
# name exits 2 rather than passing silently — it is the only thing standing
# between a typo and a test that checks nothing.
set -uo pipefail

SELF_TEST=0; REQUESTED=""

die() { echo "faults: $*" >&2; exit 2; }

# The fault matrix: slug, fault, required behaviour, and the suite that
# injects it. The single home for fault names; nothing else restates the list.
# An em dash in the last column means nothing exercises that fault, which is
# a different thing from a handled one. `decoy-port` is the inverse of a fault:
# ports are OS-assigned, so it asserts that a failure mode was designed out.
#
# `read -d ''` rather than `$(cat <<…)`: macOS bash 3.2 scans a heredoc inside
# a command substitution for quotes, and the apostrophe in "run's" ends it.
IFS= read -r -d '' MATRIX <<'ROWS'
| `offline` | Connection refused | Actionable retry; no partial state left | `FaultTests` |
| `truncate` | Truncated transfer | Resume completes | `FetchFaultTests` |
| `corrupt` | Corrupted bytes | Checksum fails **closed**; artifact discarded, not cached | `FetchFaultTests` |
| `wrong-length` | `Content-Length` disagrees with the body | Treated as corrupt, not as success | `FetchFaultTests` |
| `stall` | Stalled transfer | Distinguished from slow; user can cancel | `FaultTests` |
| `disk-full` | Disk full mid-extract | Actionable message; partial extract cleaned up | `FaultTests` |
| `quarantine` | Gatekeeper kills a downloaded binary | Reported as quarantine, never as "process failed" | `FaultTests` |
| `stale-pid` | Stale `postmaster.pid` after a crash | Recovers automatically, without data loss | `FaultTests` |
| `recycled-pid` | Pidfile names a live unrelated process | Hard block; the pidfile is validated, never blindly deleted | `FaultTests` |
| `half-initialised` | Half-initialised cluster | Detected as corrupt; re-init offered | `FaultTests` |
| `never-healthy` | SonarQube never reaches `UP` | Timeout with logs surfaced, not a spinner forever | `FaultTests` |
| `decoy-port` | A listener occupies the previous run's port | **Unaffected** — ports are OS-assigned | `PortsTests` |
ROWS

# The slug list is READ from the matrix, never restated here. Two copies drift.
known_slugs() {
  printf '%s\n' "$MATRIX" | sed -n 's/^| `\([a-z-]*\)` |.*/\1/p'
}

# And so is WHERE each one is injected, from the matrix's last column. An em
# dash means nothing exercises it yet; anything else names the suite that does.
# Read rather than listed for the same reason as the slugs: a second copy of
# this answer would go stale the first time an injector landed, and the stale
# copy would be the one claiming coverage. A second argument reads that file
# instead, which is how the self-test reads its fixture.
injector_for() {
  if [ -n "${2:-}" ]; then
    sed -n "s/^| \`$1\` |.*| \(.*\) |$/\1/p" "$2" | tail -1
  else
    printf '%s\n' "$MATRIX" | sed -n "s/^| \`$1\` |.*| \(.*\) |$/\1/p" | tail -1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --faults)    REQUESTED="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    --list)      known_slugs; exit 0 ;;
    *)           die "unknown argument '$1'" ;;
  esac
done

SLUGS="$(known_slugs)"
[ -n "$SLUGS" ] || die "the fault matrix declared no slugs — has its table changed shape?"

validate() {
  local requested="$1" slug
  IFS=',' read -ra slug <<< "$requested"
  for s in "${slug[@]}"; do
    grep -qx "$s" <<< "$SLUGS" || die "unknown fault '$s'. Known: $(tr '\n' ' ' <<< "$SLUGS")"
  done
}

if [ "$SELF_TEST" -eq 1 ]; then
  # Prove the rejection works, because a --faults typo that passes silently is
  # the failure this guard exists for.
  if ( validate "definitely-not-a-fault" ) 2>/dev/null; then
    echo "faults: SELF-TEST FAILED — an unknown slug was accepted" >&2; exit 2
  fi
  validate "$(head -1 <<< "$SLUGS")" || { echo "faults: SELF-TEST FAILED — a known slug was rejected" >&2; exit 2; }
  # ⚠ And that the injector column is READ, not assumed. A `sed` matching
  # nothing reports every fault as uninjected — the safe direction, but it
  # would hide real coverage; one matching everything claims coverage for all
  # twelve, which is the direction that matters.
  #
  # ⚠ Both arms run against a FIXTURE, not against real rows, so the check
  # tests the reading of the table rather than its current state. A real row
  # is still read below, for the shape of the file itself.
  fixture="$(mktemp -t oilbird-faults)"
  printf '%s\n' \
    '| `fixture-injected` | A fault | Its required behaviour | `ExampleTests` |' \
    '| `fixture-bare` | A fault | Its required behaviour | — |' > "$fixture"
  [ "$(injector_for fixture-injected "$fixture")" = '`ExampleTests`' ] || {
    rm -f "$fixture"
    echo "faults: SELF-TEST FAILED — an injected fault read as uninjected" >&2; exit 2; }
  [ "$(injector_for fixture-bare "$fixture")" = "—" ] || {
    rm -f "$fixture"
    echo "faults: SELF-TEST FAILED — an uninjected fault read as injected" >&2; exit 2; }
  rm -f "$fixture"
  [ -n "$(injector_for truncate)" ] || {
    echo "faults: SELF-TEST FAILED — the matrix's own rows do not read" >&2; exit 2; }
  injected=$(for s in $SLUGS; do w="$(injector_for "$s")"; [ -n "$w" ] && [ "$w" != "—" ] && echo "$s"; done | wc -l | tr -d ' ')
  bare=$(for s in $SLUGS; do w="$(injector_for "$s")"; { [ -z "$w" ] || [ "$w" = "—" ]; } && echo "$s"; done)
  echo "faults: $(wc -l <<< "$SLUGS" | tr -d ' ') slugs read from the matrix, $injected injected"
  [ -z "$bare" ] || echo "faults: nothing injects: $(tr '\n' ' ' <<< "$bare")"
  echo "faults: self-test passed — it has been made to fail on purpose (E5)"
  exit 0
fi

[ -n "$REQUESTED" ] || die "name faults with --faults, or --list them"
validate "$REQUESTED"

# ⚠ Exit 3 for a slug nothing injects, and it is not a failure — it is this
# script refusing to imply coverage it does not have. Exit 0 only when the
# matrix names something that exercises the fault, and then it says what, so
# the reader can go and read the assertions rather than trust this line.
missing=0
IFS=',' read -ra wanted <<< "$REQUESTED"
for slug in "${wanted[@]}"; do
  where="$(injector_for "$slug")"
  if [ -z "$where" ] || [ "$where" = "—" ]; then
    echo "faults: '$slug' is declared and nothing injects it" >&2
    missing=1
  else
    echo "faults: '$slug' is injected by $where — run it with 'make test'"
  fi
done
[ "$missing" -eq 0 ] || exit 3
exit 0
