#!/bin/bash
# thermal-guard test suite — runs anywhere, proves the adaptive engine.
#
# SPDX-FileCopyrightText: 2026 Anatoli Iliev
# SPDX-License-Identifier: MIT
#
# Requirements this suite deliberately meets, because CI runners have none of
# the hardware this daemon exists for:
#
#   no temperature sensor, no Intel RAPL, no network, no root.
#
# How that is achieved:
#
#   * Every physics assertion goes through `--simulate`, which by contract
#     writes no hardware register and opens no socket.
#   * The machine's stock RATING is pinned with $THERMAL_GUARD_ASSUME_STOCK_W,
#     which overrides detection outright. That makes the numbers identical on a
#     bare CI runner and on a developer's laptop that really does have RAPL and
#     publishes a rating of its own. $THERMAL_GUARD_STATE/stock-power-limit-uw is
#     also written, but only as the snapshot — the thing restored on exit — which
#     is a different question from the rating and is no longer consulted for
#     budgets. Getting those two confused is precisely the defect this suite now
#     regression-tests (section 8c).
#   * Tjmax is pinned with $THERMAL_GUARD_ASSUME_TJMAX_C, which only fills in a
#     Tjmax the hardware did not report. On a machine whose coretemp reports a
#     different Tjmax, the two tests that actually depend on Tjmax report SKIP
#     rather than a false failure; everything else sets CRIT_C explicitly so
#     Tjmax drops out of the arithmetic.
#   * `curl` and `wget` stubs are placed first on PATH. They never fetch: they
#     append to a marker file and exit 1. Any test that ends with that marker
#     present has caught the daemon reaching for the network.
#   * The guard loop is never run as root, and never with a config that caps
#     anything, so this script cannot write a power limit on a real machine.
#
# Usage:  bash tests/run-tests.sh            (exit 0 = all green)
#         VERBOSE=1 bash tests/run-tests.sh  (echo every command's output)

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
TG="$ROOT/thermal-guard"

[[ -x "$TG" ]] || { echo "cannot find an executable $TG" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/thermal-guard-tests.XXXXXX") || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- fixture ----
STATE="$WORK/state"
STOCK_W=17                 # the reference machine's real TDP
STOCK_UW=17000000
TJMAX=105                  # the reference machine's real Tjmax
CEILING=17                 # BUDGET_MAX_W defaults to the stock limit
FLOOR=4.25                 # BUDGET_MIN_W defaults to max(4, 0.25 x stock)

reset_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  printf '%s\n' "$STOCK_UW" > "$STATE/stock-power-limit-uw"
}
reset_state

BIN="$WORK/bin"; mkdir -p "$BIN"
NETMARK="$WORK/network-was-used"
for prog in curl wget; do
  cat > "$BIN/$prog" <<EOF
#!/bin/sh
# Test stub. thermal-guard must never reach this in any offline mode.
printf '%s %s\n' "\$0" "\$*" >> "$NETMARK"
exit 1
EOF
  chmod +x "$BIN/$prog"
done
PATH="$BIN:$PATH"; export PATH

export THERMAL_GUARD_STATE="$STATE"
export THERMAL_GUARD_ASSUME_TJMAX_C="$TJMAX"
export THERMAL_GUARD_ASSUME_STOCK_W="$STOCK_W"

ALLRESULTS="$WORK/all-result-lines.txt"; : > "$ALLRESULTS"

# --------------------------------------------------------------- harness -----
PASS=0; FAIL=0; SKIPPED=0
declare -a FAILURES=()
GROUP="-"

group() { GROUP=$1; printf '\n=== %s\n' "$1"; }
pass()  { PASS=$((PASS+1));    printf '  ok    %s\n' "$1"; return 0; }
skip()  { SKIPPED=$((SKIPPED+1)); printf '  skip  %s  (%s)\n' "$1" "$2"; return 0; }
fail()  {
  FAIL=$((FAIL+1))
  FAILURES+=("[$GROUP] $1${2:+ | $2}")
  printf '  FAIL  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  return 0
}

assert_eq() {          # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {    # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "output does not contain [$3]"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "output unexpectedly contains [$3]"; fi
}
assert_within() {      # name expected actual tolerance
  if awk -v a="$3" -v b="$2" -v t="$4" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t+1e-9)}'
  then pass "$1"; else fail "$1" "expected $2 +/- $4, got $3"; fi
}
assert_le() {          # name a b   (asserts a <= b numerically)
  if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a<=b+1e-9)}'
  then pass "$1"; else fail "$1" "expected $2 <= $3"; fi
}
assert_ge() {          # name a b
  if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a>=b-1e-9)}'
  then pass "$1"; else fail "$1" "expected $2 >= $3"; fi
}

mkconf() { local f=$1; shift; printf '%s\n' "$@" > "$f"; }

# Pull one field out of a RESULT line. Values never contain spaces, which the
# grammar test below asserts, so plain field splitting is exact.
rfield() {             # $1 = key ; text on stdin
  awk -v k="$1" '
    index($0, "RESULT v=1") {
      for (i = 1; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0 && substr($i, 1, p-1) == k) { print substr($i, p+1); exit }
      }
    }'
}

# Every daemon invocation goes through these, so every RESULT line the suite
# ever produces is collected and grammar-checked at the end.
#
# These are always called inside $( ), i.e. in a subshell, so an exit status
# cannot come back in a variable. It is written to a file instead and read with
# lastrc.
RCFILE="$WORK/.last-exit-status"; printf '0' > "$RCFILE"
lastrc() { cat "$RCFILE" 2>/dev/null || printf '99'; }

run_tg() {             # $1 = config path, rest = argv ; records rc, prints output
  local cfg=$1 out rc; shift
  out=$(THERMAL_GUARD_CONFIG="$cfg" "$TG" "$@" 2>&1); rc=$?
  printf '%s' "$rc" > "$RCFILE"
  printf '%s\n' "$out" | grep -F 'RESULT v=1' >> "$ALLRESULTS" 2>/dev/null
  if [[ -n "${VERBOSE:-}" ]]; then
    printf -- '--- %s %s (rc=%s)\n%s\n' "$cfg" "$*" "$rc" "$out" >&2
  fi
  printf '%s\n' "$out"
  return 0
}
detect() { run_tg "$1" --detect; }
sim()    { run_tg "$1" --simulate "$2"; }

NOCONF="$WORK/nonexistent.conf"    # deliberately never created
EMPTY="$WORK/empty.conf";  : > "$EMPTY"

printf 'thermal-guard test suite\n'
printf '  daemon    : %s\n' "$TG"
printf '  version   : %s\n' "$("$TG" --version 2>&1)"
printf '  workspace : %s\n' "$WORK"
printf '  fixture   : Tjmax %sC, stock %sW (band %sW..%sW), curl/wget stubbed\n' \
  "$TJMAX" "$STOCK_W" "$FLOOR" "$CEILING"
printf '  running as: uid %s%s\n' "$EUID" "$( ((EUID==0)) && printf ' (root — hardware-touching tests will be skipped)')"

# ============================================================================
group "0. fixture preflight — everything below depends on these"
# ============================================================================
REF="$WORK/ref.conf"        # the spec's ground-truth config, verbatim
mkconf "$REF" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
              'TIER_HYSTERESIS=7'

out=$(sim "$REF" ambient=25)
eff_tjmax=$(rfield tjmax_c <<<"$out")
eff_ceiling=$(detect "$REF" | sed -n 's/^  budget band *: [^ ]*W \.\. \([^ ]*\)W .*/\1/p')

assert_eq "stock power limit is pinned to ${CEILING}W (state file honoured)" "$CEILING" "$eff_ceiling"
TJMAX_OK=1
if [[ "$eff_tjmax" == "$TJMAX" ]]; then
  pass "Tjmax resolves to ${TJMAX}C"
else
  TJMAX_OK=0
  skip "Tjmax resolves to ${TJMAX}C" \
       "this machine reports Tjmax=${eff_tjmax}C from coretemp and THERMAL_GUARD_ASSUME_TJMAX_C cannot override real hardware; the two Tjmax-dependent tests will be skipped"
fi

# ============================================================================
group "1. every existing CI step still passes"
# ============================================================================
n_syn=0
for f in "$ROOT/thermal-guard" "$ROOT/install.sh" "$ROOT/uninstall.sh" \
         "$ROOT/thermal-guard.conf.example" "$ROOT"/examples/*.conf "$HERE/run-tests.sh" \
         "$ROOT/contrib/thermal-summary.sh" "$ROOT/contrib/thermal-clamps.sh"; do
  bash -n "$f" 2>"$WORK/e" || { fail "bash -n $(basename "$f")" "$(cat "$WORK/e")"; n_syn=1; }
done
(( n_syn )) || pass "bash -n on the daemon, both installers, the conf example, every examples/*.conf and this suite"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$ROOT/thermal-guard" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$HERE/run-tests.sh" "$ROOT/contrib/thermal-summary.sh" "$ROOT/contrib/thermal-clamps.sh" >"$WORK/sc" 2>&1
  then pass "shellcheck -S warning is clean"
  else fail "shellcheck -S warning is clean" "$(head -20 "$WORK/sc")"; fi
else
  skip "shellcheck -S warning is clean" "shellcheck is not installed here; the CI shellcheck job covers it"
fi

out=$("$TG" --version 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" =~ ^thermal-guard\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
then pass "--version works with no config, no sensor, no root"
else fail "--version works with no config, no sensor, no root" "rc=$rc out=[$out]"; fi

out=$("$TG" --help 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"usage:"* ]]
then pass "--help works with no config, no sensor, no root"
else fail "--help works with no config, no sensor, no root" "rc=$rc"; fi

out=$(detect "$NOCONF")
assert_eq        "--detect SUCCEEDS with no config, no sensor, no RAPL" 0 "$(lastrc)"
assert_contains  "--detect prints 'temperature source'" "$out" "temperature source"
assert_contains  "--detect prints the adaptive off-status line (spec test 2)" \
                 "$out" "status             : off (ADAPTIVE=no)"

# The existing CI step asserts the guard loop refuses to run with no sensor.
# That assertion only has meaning on a machine with no sensor — which is every
# CI runner. On a machine that HAS one the loop would legitimately start, so it
# is skipped rather than faked, and never started at all as root.
HAVE_SENSOR=1
detect "$NOCONF" | grep -q 'temperature source : NONE FOUND' && HAVE_SENSOR=0
if (( HAVE_SENSOR )); then
  skip "the guard loop refuses to start with no sensor" \
       "this machine has a temperature sensor, so refusing would be wrong; the trace-format test below covers the loop instead"
elif (( EUID == 0 )); then
  skip "the guard loop refuses to start with no sensor" "never starting the guard loop as root"
else
  out=$(THERMAL_GUARD_CONFIG="$NOCONF" timeout 10 "$TG" 2>&1); rc=$?
  if [[ "$out" == *"no usable temperature sensor"* ]] && (( rc != 0 ))
  then pass "the guard loop refuses to start with no sensor (rc=$rc)"
  else fail "the guard loop refuses to start with no sensor" "rc=$rc, output: $out"; fi
fi

n_bad=0
while IFS= read -r bad; do
  [[ -z "$bad" ]] && continue
  printf '%s\n' "$bad" > "$WORK/legacy-bad.conf"
  detect "$WORK/legacy-bad.conf" >/dev/null
  if (( $(lastrc) == 0 )); then
    fail "legacy rejection: $bad" "accepted, should have been refused"; n_bad=1
  fi
done <<'LEGACY_BAD'
POLL_SEC=abc
CRIT_SAMPLES=0
CRIT_ACTION=banana
NORMAL_WATTS=-5
CLAMP_PERF_PCT=101
DISABLE_TURBO=maybe
TIERS="85:7 80:11"
TIERS="80:abc"
TIERS="80:0"
TIERS="eighty:11"
TIER_SAMPLES=0
TIER_HYSTERESIS=0
TIERS="200:11"
LEGACY_BAD
(( n_bad )) || pass "all 13 legacy invalid configs are still refused"

n_good=0
while IFS= read -r good; do
  [[ -z "$good" ]] && continue
  printf '%s\n' "$good" > "$WORK/legacy-good.conf"
  detect "$WORK/legacy-good.conf" >/dev/null
  (( $(lastrc) == 0 )) || { fail "legacy acceptance: $good" "refused with rc=$(lastrc)"; n_good=1; }
done <<'LEGACY_GOOD'
NORMAL_WATTS=10.5
POLL_SEC=0.5
CRIT_ACTION=log-only
TIERS="80:11 85:7"
TIERS="75:13 80:11 85:7"
TIERS="85:7"
LEGACY_GOOD
(( n_good )) || pass "all 6 legacy valid configs (including decimals) are still accepted"

mkconf "$WORK/baseline-ladder.conf" 'NORMAL_WATTS=11' 'TIERS="85:7"'
out=$(detect "$WORK/baseline-ladder.conf")
assert_contains "CI grep '85C->7W' still matches" "$out" "85C->7W"
if grep -qE 'baseline budget *: 11' <<<"$out"
then pass "CI grep 'baseline budget *: 11' still matches"
else fail "CI grep 'baseline budget *: 11' still matches" "not found"; fi

# ============================================================================
group "2. GROUND TRUTH — the two points measured on the ASUS S550CA"
# ============================================================================
# Measured on the real machine (see thermal-fix/REPORT.md sections 4.2 / 4.4):
#   * 11 W settles at ~83 C indoors at ~25 C ambient, and TIERS="80:11 85:7"
#     is the ladder that was hand-tuned and shipped as examples/*-tiered.conf.
#   * at 34 C ambient an 11 W ladder clamped repeatedly and was SLOWER than a
#     steady 9 W; 9 W settles at ~81 C.
#
# TOLERANCES, stated explicitly:
#   watts   +/- 0.5 W  = exactly one BUDGET_STEP_W quantisation step. A budget
#                        that is off by more than one step is a different plan.
#   rung C  exact      — rung temperatures are integers derived from CRIT_C,
#                        with no rounding anywhere, so any drift is a defect.
#   tiers   byte-exact — the spec requires the generated ladder to be
#                        byte-identical to the shipped hand-written one.
#   mode/reason exact  — closed vocabularies.

out=$(sim "$REF" ambient=25)
assert_eq     "A: ambient 25C -> mode"            ladder    "$(rfield mode <<<"$out")"
assert_eq     "A: ambient 25C -> reason"          window-ok "$(rfield reason <<<"$out")"
assert_eq     "A: ambient 25C -> budget_src"      engine    "$(rfield budget_src <<<"$out")"
assert_within "A: ambient 25C -> budget is 11W +/- 0.5W (one step)" \
              11 "$(rfield budget_w <<<"$out")" 0.5
assert_eq     "A: ambient 25C -> tiers byte-identical to the shipped ladder" \
              "80:11,85:7" "$(rfield tiers <<<"$out")"
assert_eq     "A: ambient 25C -> die target 83C (CRIT_C 88 - margin 5)" \
              83 "$(rfield target_c <<<"$out")"
assert_eq     "A: ambient 25C -> top-rung clamp 7W" 7 "$(rfield clamp_w <<<"$out")"
assert_contains "A: human block prints TIERS=\"80:11 85:7\" (spec test 6)" \
              "$out" 'TIERS="80:11 85:7"'
assert_contains "A: human block says the decision is a LADDER" "$out" "decision                 LADDER"
assert_eq     "A: --simulate exits 0" 0 "$(lastrc)"

out=$(sim "$REF" ambient=34)
assert_eq     "B: ambient 34C -> mode"       constant         "$(rfield mode <<<"$out")"
assert_eq     "B: ambient 34C -> reason"     window-too-small "$(rfield reason <<<"$out")"
assert_eq     "B: ambient 34C -> no ladder"  "-"              "$(rfield tiers <<<"$out")"
assert_within "B: ambient 34C -> budget is 9W +/- 0.5W (one step)" \
              9 "$(rfield budget_w <<<"$out")" 0.5
assert_eq     "B: ambient 34C -> legacy clamp is 70% of the budget" 6.30 "$(rfield clamp_w <<<"$out")"
assert_contains "B: human block says CONSTANT CAP 9W" "$out" "decision                 CONSTANT CAP 9W"
assert_contains "B: human block would apply NORMAL_WATTS=9" "$out" "NORMAL_WATTS=9"

# Sanity check on the physics itself, independent of the daemon: the die the
# chosen budget predicts must land within 2 C of what was actually measured.
pred25=$(awk -v a=25 -v r=5.24 -v p="$(sim "$REF" ambient=25 | rfield budget_w)" 'BEGIN{printf "%.1f", a+r*p}')
pred34=$(awk -v a=34 -v r=5.24 -v p="$(sim "$REF" ambient=34 | rfield budget_w)" 'BEGIN{printf "%.1f", a+r*p}')
assert_within "A: predicted die at the chosen budget matches the measured 83C (+/-2C)" 83 "$pred25" 2
assert_within "B: predicted die at the chosen budget matches the measured 81C (+/-2C)" 81 "$pred34" 2

# Both anchors again with NO measured Rtheta at all — the general formula.
if (( TJMAX_OK )); then
  DERIVED="$WORK/derived.conf"
  mkconf "$DERIVED" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'CRIT_C=88' 'TIER_HYSTERESIS=7'
  out=$(sim "$DERIVED" ambient=25)
  assert_eq "derived Rtheta: rtheta_src" derived "$(rfield rtheta_src <<<"$out")"
  assert_eq "derived Rtheta: (105-40)/17 x 1.4 = 5.35 C/W" 5.35 "$(rfield rtheta <<<"$out")"
  assert_eq "derived Rtheta: ambient 25C -> ladder" ladder "$(rfield mode <<<"$out")"
  assert_within "derived Rtheta: ambient 25C -> 10.5W, i.e. within one step of the measured 11W, conservative side" \
                11 "$(rfield budget_w <<<"$out")" 0.5
  assert_le "derived Rtheta: ambient 25C -> never above the measured budget" \
            "$(rfield budget_w <<<"$out")" 11
  assert_eq "derived Rtheta: ambient 25C -> tiers" "80:10.5,85:6.5" "$(rfield tiers <<<"$out")"
  out=$(sim "$DERIVED" ambient=34)
  assert_eq "derived Rtheta: ambient 34C -> constant" constant "$(rfield mode <<<"$out")"
  assert_within "derived Rtheta: ambient 34C -> 9W +/- 0.5W" 9 "$(rfield budget_w <<<"$out")" 0.5
else
  skip "the derived-Rtheta general formula reproduces both anchors" "needs Tjmax=${TJMAX}C"
fi

# ============================================================================
group "3. MONOTONICITY and the budget band"
# ============================================================================
SWEEP="$WORK/sweep.txt"; : > "$SWEEP"
for a in -10 -5 0 5 10 15 20 25 30 35 40 45; do
  o=$(sim "$REF" "ambient=$a")
  printf '%s %s %s %s\n' "$a" "$(rfield budget_w <<<"$o")" "$(rfield mode <<<"$o")" \
                          "$(rfield budget_src <<<"$o")" >> "$SWEEP"
done

if bad=$(awk 'NR>1 && $2 > prev + 1e-9 { printf "%sC gives %sW, warmer than %sC which gave %sW\n", $1, $2, pa, prev }
              { prev=$2; pa=$1 }' "$SWEEP") && [[ -z "$bad" ]]
then pass "colder ambient never yields a smaller budget (-10C..45C in 5C steps)"
else fail "colder ambient never yields a smaller budget (-10C..45C in 5C steps)" "$bad"; fi

if bad=$(awk -v c="$CEILING" '$2 > c + 1e-9 { printf "%sC -> %sW exceeds the %sW ceiling\n", $1, $2, c }' "$SWEEP") \
   && [[ -z "$bad" ]]
then pass "no budget anywhere in the sweep exceeds the ${CEILING}W ceiling"
else fail "no budget anywhere in the sweep exceeds the ${CEILING}W ceiling" "$bad"; fi

if bad=$(awk -v f="$FLOOR" '$2 < f - 1e-9 { printf "%sC -> %sW is below the %sW floor\n", $1, $2, f }' "$SWEEP") \
   && [[ -z "$bad" ]]
then pass "no budget anywhere in the sweep falls below the ${FLOOR}W floor"
else fail "no budget anywhere in the sweep falls below the ${FLOOR}W floor" "$bad"; fi

# Exactly one ladder -> constant transition, and never back.
modes=$(awk '{printf "%s ", $3}' "$SWEEP")
uniq_modes=$(awk '{ if ($3 != last) { printf "%s ", $3; last=$3 } }' "$SWEEP")
assert_eq "mode transitions ladder -> constant exactly once and never back" \
          "ladder constant " "$uniq_modes"
[[ -n "$modes" ]] || fail "sweep produced modes" "empty"

# Both ends of the band actually bind.
out=$(sim "$REF" ambient=-60)
assert_eq "coldest allowed ambient (-60C) clips at the ceiling" clipped-ceiling "$(rfield budget_src <<<"$out")"
assert_eq "coldest allowed ambient (-60C) budget equals the ${CEILING}W stock ceiling" "$CEILING" "$(rfield budget_w <<<"$out")"
out=$(sim "$REF" ambient=70)
assert_eq "hottest allowed ambient (70C) clips at the floor" clipped-floor "$(rfield budget_src <<<"$out")"
assert_eq "hottest allowed ambient (70C) budget equals the ${FLOOR}W floor" "$FLOOR" "$(rfield budget_w <<<"$out")"

# The measured crossover (spec test 10): ladder at 31 C, constant at 34 C.
assert_eq "crossover: 31C ambient still prefers a ladder"  ladder   "$(sim "$REF" ambient=31 | rfield mode)"
assert_eq "crossover: 32C ambient drops to a constant cap" constant "$(sim "$REF" ambient=32 | rfield mode)"
assert_eq "crossover: 34C ambient is a constant cap"       constant "$(sim "$REF" ambient=34 | rfield mode)"

# Placement transform (spec test 11).
IND="$WORK/indoor.conf"; OUTD="$WORK/outdoor.conf"
mkconf "$IND"  'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIER_HYSTERESIS=7' 'PLACEMENT=indoor'
mkconf "$OUTD" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIER_HYSTERESIS=7' 'PLACEMENT=outdoor'
assert_eq "indoor: an outdoor reading of 34C becomes 26.2C in the room (22 + 0.35 x 12)" \
          26.2 "$(sim "$IND" 34 | rfield ambient_c)"
assert_eq "outdoor: an outdoor reading of 34C is used as-is" \
          34.0 "$(sim "$OUTD" 34 | rfield ambient_c)"
assert_eq "indoor: a freezing outdoor reading is floored at INDOOR_BASE_C, not extrapolated" \
          22.0 "$(sim "$IND" -30 | rfield ambient_c)"

# ============================================================================
group "4. FAIL-SAFE — unknown, stale, corrupt and hostile ambient"
# ============================================================================
# Every case here must land on AMBIENT_FALLBACK_C=35 -> a constant 9 W cap, and
# must never build a ladder or exceed the ceiling.
WXCONF="$WORK/weather.conf"
mkconf "$WXCONF" 'ADAPTIVE=yes' 'LOCATION=auto' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIER_HYSTERESIS=7'
FALLBACK_BUDGET=9
NOW=$(date +%s)

wxfile() { printf '%s' "$1" > "$STATE/weather"; }

check_failsafe() {     # $1 = human name, $2 = expected ambient_src
  local name=$1 wantsrc=$2 o
  o=$(detect "$WXCONF")
  local src mode reason budget tiers
  src=$(rfield ambient_src <<<"$o"); mode=$(rfield mode <<<"$o")
  reason=$(rfield reason <<<"$o");   budget=$(rfield budget_w <<<"$o")
  tiers=$(rfield tiers <<<"$o")
  if [[ "$src" == "$wantsrc" && "$mode" == constant && "$reason" == ambient-unknown \
        && "$budget" == "$FALLBACK_BUDGET" && "$tiers" == "-" ]]; then
    pass "fail-safe: $name -> fallback ambient, constant ${FALLBACK_BUDGET}W, no ladder"
  else
    fail "fail-safe: $name -> fallback ambient, constant ${FALLBACK_BUDGET}W, no ladder" \
         "got ambient_src=$src mode=$mode reason=$reason budget_w=$budget tiers=$tiers"
  fi
  assert_le "fail-safe: $name never exceeds the ${CEILING}W ceiling" "$budget" "$CEILING"
}

rm -f "$STATE/weather";                                    check_failsafe "no cache file at all" fallback
wxfile ""    ;                                             check_failsafe "empty cache file" fallback
wxfile $'%%%\nthis is not a cache\n\x01\x02'             ; check_failsafe "corrupt cache file" fallback
wxfile "$(printf 'fetched_at=%s\nstatus=ok\n' "$NOW")"   ; check_failsafe "cache with no temp_c" fallback
wxfile "$(printf 'temp_c=29.4\nfetched_at=%s\nstatus=ok\n' $((NOW-21600)))" ; check_failsafe "cache 6h stale (max age 3h)" fallback
wxfile "$(printf 'temp_c=29.4\nfetched_at=%s\nstatus=ok\n' $((NOW+7200))) " ; check_failsafe "cache timestamped in the future (clock stepped back)" fallback
wxfile "$(printf 'temp_c=-999\nfetched_at=%s\nstatus=ok\n' "$NOW")"         ; check_failsafe "hostile temp_c=-999" fallback
wxfile "$(printf 'temp_c=999\nfetched_at=%s\nstatus=ok\n' "$NOW")"          ; check_failsafe "hostile temp_c=999" fallback
wxfile "$(printf 'temp_c=1e9\nfetched_at=%s\nstatus=ok\n' "$NOW")"          ; check_failsafe "hostile temp_c=1e9" fallback
wxfile "$(printf 'temp_c=NaN\nfetched_at=%s\nstatus=ok\n' "$NOW")"          ; check_failsafe "hostile temp_c=NaN" fallback
wxfile "$(printf 'temp_c=0; rm -rf /\nfetched_at=%s\nstatus=ok\n' "$NOW")"  ; check_failsafe "hostile temp_c='0; rm -rf /'" fallback
wxfile "$(printf 'temp_c=25\nfetched_at=not-a-number\nstatus=ok\n')"        ; check_failsafe "cache with a non-numeric fetched_at" fallback

# Nothing from either cache file may ever be executed, expanded or sourced.
PWNED="$WORK/PWNED"
wxfile "$(printf 'temp_c=$(touch %s.a)\nfetched_at=`touch %s.b`\nstatus=$(touch %s.c)\n' "$PWNED" "$PWNED" "$PWNED")"
check_failsafe "hostile temp_c with command substitution" fallback
# Sharpest form of "never sourced": the cached reading is stale, so the fallback
# ambient decides the budget — and the cache file itself claims the fallback is a
# cool 5 C. If a single line of it were sourced the budget would jump to 14.5 W.
wxfile "$(printf 'temp_c=25\nfetched_at=%s\nstatus=ok\nAMBIENT_FALLBACK_C=5\nBUDGET_MAX_W=999\nCRIT_ACTION=poweroff\n' $((NOW-99999)))"
o=$(detect "$WXCONF")
assert_eq "the weather cache is never sourced: an AMBIENT_FALLBACK_C=5 line in it changes nothing" \
          "35.0" "$(rfield ambient_c <<<"$o")"
assert_eq "the weather cache is never sourced: the budget stays the conservative ${FALLBACK_BUDGET}W" \
          "$FALLBACK_BUDGET" "$(rfield budget_w <<<"$o")"
assert_contains "the weather cache is never sourced: BUDGET_MAX_W=999 in it does not move the band" \
          "$o" "budget band        : ${FLOOR}W .. ${CEILING}W"
assert_contains "the weather cache is never sourced: CRIT_ACTION=poweroff in it does not take effect" \
          "$o" "crit action        : throttle-only"

printf 'lat=$(touch %s.d)\nlon=`touch %s.e`\nplace=; rm -rf /\nsource=geoip\nresolved=%s\n' \
  "$PWNED" "$PWNED" "$NOW" > "$STATE/location"
rm -f "$STATE/weather"
o=$(detect "$WXCONF")
assert_contains "a hostile location cache leaves the location unresolved rather than used" \
          "$o" "unresolved (LOCATION=auto)"
rm -f "$STATE/location"

if compgen -G "$PWNED"'*' >/dev/null; then
  fail "nothing in either cache file is ever executed" "these files were created: $(echo "$PWNED"*)"
else
  pass "nothing in either cache file is ever executed (no command substitution ran)"
fi

# The one case that must be TRUSTED, so the fail-safe tests above are not
# vacuously green: a fresh, plausible reading really does raise the budget.
wxfile "$(printf 'temp_c=29.4\nfetched_at=%s\nstatus=ok\n' "$NOW")"
o=$(detect "$WXCONF")
assert_eq "control: a fresh plausible reading IS used (29.4C outdoor -> 24.6C indoor)" \
          weather "$(rfield ambient_src <<<"$o")"
assert_eq "control: and it yields the 11W ladder"   "80:11,85:7" "$(rfield tiers <<<"$o")"

# A spoofed cold reading is bounded, not unbounded: indoors by INDOOR_BASE_C,
# outdoors by the stock power limit the machine ships with.
wxfile "$(printf 'temp_c=-88\nfetched_at=%s\nstatus=ok\n' "$NOW")"
o=$(detect "$WXCONF")
assert_eq "spoofed -88C indoors is floored at INDOOR_BASE_C=22, not believed" \
          22.0 "$(rfield ambient_c <<<"$o")"
assert_le "spoofed -88C indoors still cannot exceed the ceiling" "$(rfield budget_w <<<"$o")" "$CEILING"
OUTWX="$WORK/outdoor-weather.conf"
mkconf "$OUTWX" 'ADAPTIVE=yes' 'LOCATION=auto' 'PLACEMENT=outdoor' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIER_HYSTERESIS=7'
o=$(detect "$OUTWX")
assert_eq "spoofed -88C outdoors is clipped at the stock limit, the documented worst case" \
          clipped-ceiling "$(rfield budget_src <<<"$o")"
assert_le "spoofed -88C outdoors still cannot exceed the ceiling" "$(rfield budget_w <<<"$o")" "$CEILING"
rm -f "$STATE/weather"

# --simulate unknown (spec test 12)
o=$(sim "$REF" unknown)
assert_eq "--simulate unknown -> ambient_src"  fallback        "$(rfield ambient_src <<<"$o")"
assert_eq "--simulate unknown -> reason"       ambient-unknown "$(rfield reason <<<"$o")"
assert_eq "--simulate unknown -> mode"         constant        "$(rfield mode <<<"$o")"
assert_eq "--simulate unknown -> budget"       "$FALLBACK_BUDGET" "$(rfield budget_w <<<"$o")"
assert_eq "--simulate unknown exits 0 (a conservative answer is not an error)" 0 "$(lastrc)"

# An unknown ambient outranks even an explicit ADAPTIVE_MODE=ladder.
FORCED="$WORK/forced-ladder.conf"
mkconf "$FORCED" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
                 'TIER_HYSTERESIS=7' 'ADAPTIVE_MODE=ladder'
o=$(sim "$FORCED" unknown)
assert_eq "ADAPTIVE_MODE=ladder cannot force a ladder when the ambient is unknown" \
          constant "$(rfield mode <<<"$o")"
assert_eq "...and the reason names the real cause" ambient-unknown "$(rfield reason <<<"$o")"

# A ladder that could never release must be rejected, not built.
o=$(sim "$FORCED" ambient=60)
assert_eq "a ladder whose top rung could never release is rejected" \
          ladder-cannot-release "$(rfield reason <<<"$o")"
assert_eq "...and the plan falls back to a constant cap" constant "$(rfield mode <<<"$o")"

# ============================================================================
group "5. BACKWARD COMPATIBILITY — today's live config and both examples"
# ============================================================================
LIVE="$WORK/live.conf"
mkconf "$LIVE" 'NORMAL_WATTS=11' 'CLAMP_WATTS=7' 'CLAMP_PERF_PCT=40' 'DISABLE_TURBO=yes' \
               'WARN_C=85' 'CRIT_C=88' 'RECOVER_C=78' 'CRIT_SAMPLES=3' \
               'CRIT_ACTION=throttle-only' 'RESTORE_ON_EXIT=yes'

# The "effective configuration" is exactly the block --detect prints between
# 'baseline budget' and 'restore on exit'. Trailing whitespace is normalised on
# both sides so an editor cannot silently break the comparison; every value is
# still asserted.
effective_config() {
  detect "$1" | sed -n '/^  baseline budget/,/^  restore on exit/p' | sed 's/[[:space:]]*$//'
}

want_legacy=$(sed 's/[[:space:]]*$//' <<'EOF'
  baseline budget    : 11
  tier ladder        : 85C->7W
  tier engage after  : 3 samples (6s)
  tier release below : rung temp minus 7C
  top-rung perf pct  : 40
  disable turbo      : yes
  critical at        : 88C
  legacy warn/recover: 85C / 78C
  crit action        : throttle-only
  crit samples       : 3  (= 6s sustained)
  poll interval      : 2s
  restore on exit    : yes
EOF
)
want_tiered=$(sed 's/[[:space:]]*$//' <<'EOF'
  baseline budget    : stock (no cap)
  tier ladder        : 80C->11W 85C->7W
  tier engage after  : 3 samples (6s)
  tier release below : rung temp minus 7C
  top-rung perf pct  : 40
  disable turbo      : yes
  critical at        : 88C
  crit action        : throttle-only
  crit samples       : 3  (= 6s sustained)
  poll interval      : 2s
  restore on exit    : yes
EOF
)

assert_eq "the live config produces the same effective configuration as v1.1.0" \
          "$want_legacy" "$(effective_config "$LIVE")"
assert_eq "examples/asus-s550ca.conf produces the same effective configuration as v1.1.0" \
          "$want_legacy" "$(effective_config "$ROOT/examples/asus-s550ca.conf")"
assert_eq "examples/asus-s550ca-tiered.conf produces the same effective configuration as v1.1.0" \
          "$want_tiered" "$(effective_config "$ROOT/examples/asus-s550ca-tiered.conf")"

o=$(detect "$LIVE")
assert_eq "live config: mode is static, the engine does not run"  static           "$(rfield mode <<<"$o")"
assert_eq "live config: reason is adaptive-disabled"              adaptive-disabled "$(rfield reason <<<"$o")"
assert_eq "live config: the user's 11W is the budget"             11               "$(rfield budget_w <<<"$o")"
assert_eq "live config: and it is sourced from the config"        config           "$(rfield budget_src <<<"$o")"
assert_eq "live config: the legacy single rung survives"          85:7             "$(rfield tiers <<<"$o")"
assert_contains "live config: CRIT_ACTION stays throttle-only" "$o" "crit action        : throttle-only"
assert_not_contains "live config: nothing anywhere suggests powering off" "$o" "poweroff"

o=$(detect "$ROOT/examples/asus-s550ca-tiered.conf")
assert_eq "tiered example: the hand-tuned ladder is unchanged" "80:11,85:7" "$(rfield tiers <<<"$o")"
assert_eq "tiered example: mode is static" static "$(rfield mode <<<"$o")"

o=$(detect "$EMPTY")
assert_contains "an empty config still caps nothing" "$o" "Nothing will be capped"
assert_eq "an empty config still has no budget" "-" "$(rfield budget_w <<<"$o")"
assert_eq "an empty config still has no ladder" "-" "$(rfield tiers <<<"$o")"
assert_eq "an empty config reports adaptive-disabled" adaptive-disabled "$(rfield reason <<<"$o")"

n_ex=0
for f in "$ROOT"/examples/*.conf; do
  detect "$f" >/dev/null
  (( $(lastrc) == 0 )) || { fail "example accepted: $(basename "$f")" "rc=$(lastrc)"; n_ex=1; }
done
(( n_ex )) || pass "every examples/*.conf is still accepted by --detect"

o=$(sim "$EMPTY" 25)
assert_eq "--simulate with ADAPTIVE=no reports adaptive-disabled (spec test 19)" \
          adaptive-disabled "$(rfield reason <<<"$o")"
assert_contains "--simulate with ADAPTIVE=no says so in words" "$o" "adaptive is off (ADAPTIVE=no)"
assert_eq "--simulate with ADAPTIVE=no exits 0" 0 "$(lastrc)"

# The privacy promise: with none of the new keys set, nothing is fetched.
if [[ -e "$NETMARK" ]]; then
  fail "no network is contacted by any config without the new keys" "$(cat "$NETMARK")"
else
  pass "no network is contacted by any config without the new keys (curl/wget stubs untouched)"
fi
o=$(detect "$LIVE")
assert_not_contains "the live config's --detect never claims outbound HTTPS" "$o" "outbound HTTPS"

# The guard loop itself, where it can be run safely: no root, and a config that
# caps nothing, so no power limit is ever written.
if (( EUID == 0 )); then
  skip "the guard loop writes a 3-column trace and uses no network" "never starting the guard loop as root"
else
  LOOPCONF="$WORK/loop.conf"; LOOPTRACE="$WORK/loop.trace"
  mkconf "$LOOPCONF" 'POLL_SEC=0.5' "TRACE=$LOOPTRACE" 'RESTORE_ON_EXIT=no' 'DISABLE_TURBO=no'
  THERMAL_GUARD_CONFIG="$LOOPCONF" timeout 4 "$TG" >/dev/null 2>&1
  if [[ -s "$LOOPTRACE" ]] && grep -qv '^#' "$LOOPTRACE"; then
    ncsv=$(grep -cv '^#' "$LOOPTRACE")
    nbad=$(grep -v '^#' "$LOOPTRACE" | awk -F, 'NF!=3{n++} END{print n+0}')
    assert_eq "the guard loop's trace is still exactly timestamp,temp_c,clamped ($ncsv rows)" 0 "$nbad"
    maxt=$(grep -v '^#' "$LOOPTRACE" | awk -F',' '{if($2>m)m=$2} END{print m+0}')
    if [[ "$maxt" =~ ^[0-9]+$ ]] && (( maxt > 0 ))
    then pass "the README's 'max temperature' awk recipe still works (${maxt}C)"
    else fail "the README's 'max temperature' awk recipe still works" "got [$maxt]"; fi
  else
    skip "the guard loop writes a 3-column trace" "no temperature sensor on this machine, so the loop correctly refused to start"
  fi
  if [[ -e "$NETMARK" ]]; then
    fail "the running guard loop with no adaptive keys uses no network" "$(cat "$NETMARK")"
  else
    pass "the running guard loop with no adaptive keys uses no network"
  fi
fi

# ============================================================================
group "6. VALIDATION — every new key refuses nonsense"
# ============================================================================
reject() {             # $1 = human name, $2 = expected message fragment, rest = config lines
  local name=$1 want=$2; shift 2
  printf '%s\n' "$@" > "$WORK/bad.conf"
  local o; o=$(detect "$WORK/bad.conf")
  if (( $(lastrc) == 0 )); then
    fail "rejects $name" "accepted; config was: $*"
  elif [[ "$o" != *"$want"* ]]; then
    fail "rejects $name" "refused, but the message did not mention [$want]: $(head -1 <<<"$o")"
  else
    pass "rejects $name"
  fi
}
accept() {             # $1 = human name, rest = config lines
  local name=$1; shift
  printf '%s\n' "$@" > "$WORK/good.conf"
  local o; o=$(detect "$WORK/good.conf")
  if (( $(lastrc) == 0 )); then pass "accepts $name"
  else fail "accepts $name" "refused: $(head -1 <<<"$o")"; fi
}

reject "ADAPTIVE=maybe"            "ADAPTIVE must be yes or no"                'ADAPTIVE=maybe'
reject "PLACEMENT=garden"          "PLACEMENT must be indoor or outdoor"       'PLACEMENT=garden'
reject "ADAPTIVE_MODE=sideways"    "ADAPTIVE_MODE must be auto, ladder or constant" 'ADAPTIVE_MODE=sideways'
reject "ADAPTIVE_HEARTBEAT_SEC=-1" "ADAPTIVE_HEARTBEAT_SEC must be an integer" 'ADAPTIVE_HEARTBEAT_SEC=-1'
reject "LATITUDE=999"              "LATITUDE must be a number between -90 and 90" 'LATITUDE=999' 'LONGITUDE=1'
reject "LATITUDE=abc"              "LATITUDE must be a number between -90 and 90" 'LATITUDE=abc' 'LONGITUDE=1'
reject "LONGITUDE=999"             "LONGITUDE must be a number between -180 and 180" 'LATITUDE=1' 'LONGITUDE=999'
reject "LATITUDE without LONGITUDE" "set both or neither"                      'LATITUDE=42'
reject "LONGITUDE without LATITUDE" "set both or neither"                      'LONGITUDE=23'
reject "a shell-injecting LOCATION" "place names are not supported"            'LOCATION="; rm -rf /"'
reject "LOCATION=Sofia (a place name)" "place names are not supported"         'LOCATION=Sofia'
reject "LOCATION with an out-of-range latitude" "place names are not supported" 'LOCATION="999,23"'
reject "AMBIENT_C=200"             "AMBIENT_C must be a temperature between -60 and 70" 'AMBIENT_C=200'
reject "AMBIENT_FALLBACK_C=-5"     "AMBIENT_FALLBACK_C must be a temperature between 0 and 60" 'AMBIENT_FALLBACK_C=-5'
reject "AMBIENT_OFFSET_C=99"       "AMBIENT_OFFSET_C must be a number between -30 and 30" 'AMBIENT_OFFSET_C=99'
reject "INDOOR_BASE_C=90"          "INDOOR_BASE_C must be a temperature between -20 and 40" 'INDOOR_BASE_C=90'
reject "INDOOR_COUPLING=2"         "INDOOR_COUPLING must be a number between 0 and 1" 'INDOOR_COUPLING=2'
reject "RTHETA_C_PER_W=0"          "RTHETA_C_PER_W must be a number between 0.1 and 30" 'RTHETA_C_PER_W=0'
reject "RTHETA_DERATE=0.5"         "RTHETA_DERATE must be a number between 1.0 and 3.0" 'RTHETA_DERATE=0.5'
reject "DIE_TARGET_C=83.5"         "DIE_TARGET_C must be a whole number"       'DIE_TARGET_C=83.5'
reject "DIE_TARGET_MARGIN_C=0"     "DIE_TARGET_MARGIN_C must be an integer between 1 and 40" 'DIE_TARGET_MARGIN_C=0'
reject "BUDGET_MIN_W=-1"           "BUDGET_MIN_W must be a number in watts"    'BUDGET_MIN_W=-1'
reject "BUDGET_MAX_W=0"            "BUDGET_MAX_W must be greater than zero"    'BUDGET_MAX_W=0'
reject "BUDGET_STEP_W=0"           "BUDGET_STEP_W must be greater than zero"   'BUDGET_STEP_W=0'
reject "LADDER_START_MARGIN_C=0"   "LADDER_START_MARGIN_C must be an integer >= 1" 'LADDER_START_MARGIN_C=0'
reject "LADDER_TOP_MARGIN_C=0"     "LADDER_TOP_MARGIN_C must be an integer >= 1" 'LADDER_TOP_MARGIN_C=0'
reject "LADDER_TOP_FACTOR=1.5"     "LADDER_TOP_FACTOR must be greater than 0 and at most 1" 'LADDER_TOP_FACTOR=1.5'
reject "LADDER_TOP_FACTOR=0"       "LADDER_TOP_FACTOR must be greater than 0 and at most 1" 'LADDER_TOP_FACTOR=0'
reject "LADDER_MIN_WINDOW_C=abc"   "LADDER_MIN_WINDOW_C must be a number"      'LADDER_MIN_WINDOW_C=abc'
reject "LADDER_IDLE_RISE_C=-3"     "LADDER_IDLE_RISE_C must be a number"       'LADDER_IDLE_RISE_C=-3'
reject "a plaintext WEATHER_URL"   "must be an https:// URL"                   'WEATHER_URL="http://x"'
reject "a WEATHER_URL with a backtick" "must be an https:// URL"               "WEATHER_URL='https://x\`y'"
reject "a WEATHER_URL with a space" "must be an https:// URL"                  "WEATHER_URL='https://x y'"
reject "a GEOIP_URL with a pipe"   "must be an https:// URL"                   "GEOIP_URL='https://x|y'"
reject "a non-https GEOIP_URL"     "must be an https:// URL"                   'GEOIP_URL="ftp://x"'
reject "WEATHER_INTERVAL_SEC=0"    "WEATHER_INTERVAL_SEC must be an integer >= 600" 'WEATHER_INTERVAL_SEC=0'
reject "WEATHER_TIMEOUT_SEC=0"     "WEATHER_TIMEOUT_SEC must be an integer between 1 and 120" 'WEATHER_TIMEOUT_SEC=0'
reject "WEATHER_TIMEOUT_SEC=999"   "WEATHER_TIMEOUT_SEC must be an integer between 1 and 120" 'WEATHER_TIMEOUT_SEC=999'
reject "WEATHER_MAX_AGE_SEC below WEATHER_INTERVAL_SEC" "every reading is stale before the next fetch" 'WEATHER_MAX_AGE_SEC=100'

# Cross-key contradictions the spec says must be refused.
reject "BUDGET_MIN_W above BUDGET_MAX_W"  "the budget band is empty" 'BUDGET_MIN_W=12' 'BUDGET_MAX_W=8'
reject "DIE_TARGET_C at or above CRIT_C"  "must be below CRIT_C"     'DIE_TARGET_C=95' 'CRIT_C=88'
reject "DIE_TARGET_C at or above Tjmax"   "the hardware acts first"  'ADAPTIVE=yes' 'AMBIENT_C=25' 'CRIT_C=110'
reject "a ladder whose rungs collapse into each other" "the ladder collapses" \
       'ADAPTIVE=yes' 'AMBIENT_C=25' 'CRIT_C=88' 'LADDER_START_MARGIN_C=1' 'LADDER_TOP_MARGIN_C=10'
reject "ADAPTIVE=yes with nowhere to get an ambient" "there is nowhere to get an ambient temperature" 'ADAPTIVE=yes'

accept "ADAPTIVE=yes with LOCATION=auto"        'ADAPTIVE=yes' 'LOCATION=auto'
accept "ADAPTIVE=yes with AMBIENT_C"            'ADAPTIVE=yes' 'AMBIENT_C=25'
accept "ADAPTIVE=yes with explicit coordinates" 'ADAPTIVE=yes' 'LATITUDE=42.7' 'LONGITUDE=23.3'
accept "ADAPTIVE=yes with LOCATION=\"lat,lon\"" 'ADAPTIVE=yes' 'LOCATION="42.7,23.3"'
accept "negative coordinates"                   'ADAPTIVE=yes' 'LATITUDE=-42.7' 'LONGITUDE=-23.3'
accept "ADAPTIVE=no with every new key set to a valid value" \
  'ADAPTIVE=no' 'PLACEMENT=outdoor' 'LOCATION=auto' 'AMBIENT_OFFSET_C=-3' 'ADAPTIVE_MODE=ladder' \
  'LATITUDE=-42.7' 'LONGITUDE=-23.3' 'AMBIENT_C=25' 'AMBIENT_FALLBACK_C=40' 'RTHETA_C_PER_W=5.24' \
  'DIE_TARGET_C=83' 'BUDGET_MIN_W=4' 'BUDGET_MAX_W=17' 'INDOOR_BASE_C=22' 'INDOOR_COUPLING=0.35' \
  'DIE_TARGET_MARGIN_C=5' 'RTHETA_DERATE=1.4' 'BUDGET_STEP_W=0.5' 'LADDER_START_MARGIN_C=3' \
  'LADDER_TOP_MARGIN_C=3' 'LADDER_TOP_FACTOR=0.65' 'LADDER_MIN_WINDOW_C=8' 'LADDER_IDLE_RISE_C=40' \
  'WEATHER_URL="https://example.invalid/x?lat={lat}&lon={lon}"' 'GEOIP_URL="https://example.invalid/geo"' \
  'WEATHER_INTERVAL_SEC=600' 'WEATHER_TIMEOUT_SEC=10' 'WEATHER_MAX_AGE_SEC=10800' \
  'ADAPTIVE_HEARTBEAT_SEC=0' 'CRIT_C=88'

# ============================================================================
group "7. PARSER — the security boundary, no network needed"
# ============================================================================
parses() {             # $1 = name, $2 = expected value, $3 = body
  local o; o=$(printf '%s' "$3" | "$TG" --selftest-parse 2>/dev/null); local rc=$?
  if (( rc == 0 )) && [[ "$o" == "$2" ]]
  then pass "parser accepts $1 -> $2"
  else fail "parser accepts $1 -> $2" "rc=$rc out=[$o]"; fi
}
refuses() {            # $1 = name, $2 = body
  local o; o=$(printf '%s' "$2" | "$TG" --selftest-parse 2>/dev/null); local rc=$?
  if (( rc != 0 )) && [[ -z "$o" ]]
  then pass "parser refuses $1"
  else fail "parser refuses $1" "rc=$rc out=[$o]"; fi
}

REAL_BODY='{"latitude":42.6875,"longitude":23.3125,"generationtime_ms":0.03,"utc_offset_seconds":0,"timezone":"GMT","elevation":562.0,"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C"},"current":{"time":"2026-08-07T13:45","interval":900,"temperature_2m":23.9}}'
parses  "a real Open-Meteo body"        23.9   "$REAL_BODY"
parses  "a negative temperature"       -12.4   '{"current_units":{"temperature_2m":"C"},"current":{"time":"x","interval":900,"temperature_2m":-12.4}}'
parses  "spec-legal spacing \"current\" : {" 18.5 '{"current_units":{"temperature_2m":"C"},"current" : {"time":"x","temperature_2m":18.5}}'
parses  "a plausible extreme (-89.5)"  -89.5   '{"current":{"temperature_2m":-89.5}}'
refuses "an empty body"                        ''
refuses "an HTML captive portal"               '<html><head><title>Login</title></head><body>temperature_2m 25</body></html>'
refuses "Open-Meteo's own 400 error JSON"      '{"error":true,"reason":"Latitude must be in range of -90 to 90. Given: 999.0."}'
refuses "a body missing the field"             '{"current":{"time":"x","interval":900}}'
refuses "the units-string trap (current_units only)" '{"current_units":{"time":"iso8601","temperature_2m":"C"}}'
refuses "a quoted value"                       '{"current":{"temperature_2m":"25.0"}}'
refuses "1e9 (which would truncate to 1)"      '{"current":{"temperature_2m":1e9}}'
refuses "NaN"                                  '{"current":{"temperature_2m":NaN}}'
refuses "null"                                 '{"current":{"temperature_2m":null}}'
refuses "a body containing backticks"          '{"current":{"temperature_2m":`id`}}'
refuses "shell injection in the value"         '{"current":{"temperature_2m":25;rm -rf /}}'
refuses "an implausibly hot reading (85C)"     '{"current":{"temperature_2m":85.0}}'
refuses "an implausibly cold reading (-95C)"   '{"current":{"temperature_2m":-95.0}}'

printf '{"current":{"temperature_2m":\0\00025.0}}' | "$TG" --selftest-parse >"$WORK/p" 2>/dev/null
if (( $? != 0 )) && [[ ! -s "$WORK/p" ]]
then pass "parser refuses a body containing NUL bytes"
else fail "parser refuses a body containing NUL bytes" "out=[$(cat "$WORK/p")]"; fi

{ printf '{"current":{"temperature_2m":'; head -c 10000000 /dev/zero | tr '\0' 'x'; printf '}}'; } \
  | timeout 60 "$TG" --selftest-parse >"$WORK/p" 2>/dev/null
if (( $? != 0 )) && [[ ! -s "$WORK/p" ]]
then pass "parser refuses a 10 MB body without hanging"
else fail "parser refuses a 10 MB body without hanging" "out=[$(head -c 40 "$WORK/p")]"; fi

# ============================================================================
group "8. PRECEDENCE — the user's own numbers always win"
# ============================================================================
PIN="$WORK/pinned.conf"
mkconf "$PIN" 'ADAPTIVE=yes' 'AMBIENT_C=34' 'NORMAL_WATTS=11' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88'
o=$(detect "$PIN")
assert_eq "a literal NORMAL_WATTS pins the plan: mode"       static "$(rfield mode <<<"$o")"
assert_eq "a literal NORMAL_WATTS pins the plan: reason"     pinned "$(rfield reason <<<"$o")"
assert_eq "a literal NORMAL_WATTS pins the plan: the 11W survives" 11 "$(rfield budget_w <<<"$o")"
assert_eq "a literal NORMAL_WATTS pins the plan: budget_src" config "$(rfield budget_src <<<"$o")"
assert_contains "the engine's opinion is labelled ADVISORY ONLY" "$o" "ADVISORY ONLY"
assert_contains "and it warns that 11W is above the 9W this ambient supports" "$o" "is above the 9W this ambient (34.0C) supports"

PIN2="$WORK/pinned-tiers.conf"
mkconf "$PIN2" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'TIERS="85:7"' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88'
o=$(detect "$PIN2")
assert_eq "a literal TIERS pins the plan"         pinned "$(rfield reason <<<"$o")"
assert_eq "a literal TIERS survives untouched"    85:7   "$(rfield tiers <<<"$o")"
assert_contains "the legacy '85C->7W' grep still matches under ADAPTIVE=yes" "$o" "85C->7W"

PIN3="$WORK/pinned-clamp.conf"
mkconf "$PIN3" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'CLAMP_WATTS=7' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88'
assert_eq "a literal CLAMP_WATTS also pins the plan" pinned "$(detect "$PIN3" | rfield reason)"

MODEC="$WORK/mode-constant.conf"
mkconf "$MODEC" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'ADAPTIVE_MODE=constant'
o=$(sim "$MODEC" ambient=25)
assert_eq "ADAPTIVE_MODE=constant forces a flat cap even where a ladder fits" constant "$(rfield mode <<<"$o")"
assert_eq "...and says why"  mode-forced-constant "$(rfield reason <<<"$o")"
o=$(sim "$FORCED" ambient=34)
assert_eq "ADAPTIVE_MODE=ladder forces a ladder even where the window is small" ladder "$(rfield mode <<<"$o")"
assert_eq "...and says why"  mode-forced-ladder "$(rfield reason <<<"$o")"

MAN="$WORK/manual-ambient.conf"
mkconf "$MAN" 'ADAPTIVE=yes' 'AMBIENT_C=34' 'LOCATION=auto' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88'
wxfile "$(printf 'temp_c=10\nfetched_at=%s\nstatus=ok\n' "$NOW")"
o=$(detect "$MAN")
assert_eq "AMBIENT_C beats even a fresh weather reading" manual "$(rfield ambient_src <<<"$o")"
assert_eq "...and the ambient really is the configured one" 34.0 "$(rfield ambient_c <<<"$o")"
assert_contains "...and no network is used at all" "$o" "nothing is fetched"
rm -f "$STATE/weather"

# ============================================================================
group "8b. REGRESSIONS — every defect adversarial review found, kept dead"
# ============================================================================
# One assertion per confirmed finding, worded so a failure says which one came
# back. Three of the twelve (the geocoder cache, the fetch deadline and the
# orphaned curl/wget) live entirely in the network fetch path and cannot be
# asserted here without invoking the stubbed curl, which would break the
# hermeticity promise this suite exists to protect — they are covered by the
# manual on-machine tests in the spec's section 12 instead.

# --- a ladder whose working rung settles at or above the emergency rung -------
# Raising LADDER_TOP_MARGIN_C is what the docs suggest for more overshoot
# margin, and it used to build a permanently-oscillating ladder in silence.
WIDE="$WORK/wide-top-margin.conf"
mkconf "$WIDE" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
               'TIER_HYSTERESIS=7' 'LADDER_TOP_MARGIN_C=6'
o=$(sim "$WIDE" ambient=25)
assert_eq "LADDER_TOP_MARGIN_C=6 lowers the die target under the emergency rung" \
  81 "$(rfield target_c <<<"$o")"
assert_eq "...and the ladder it builds has the budget settling below that rung" \
  "78:10.5,82:6.5" "$(rfield tiers <<<"$o")"
assert_contains "...and it says so, naming both keys" "$(detect "$WIDE")" \
  "LADDER_TOP_MARGIN_C below DIE_TARGET_MARGIN_C"

HIGHT="$WORK/high-die-target.conf"
mkconf "$HIGHT" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
                'TIER_HYSTERESIS=7' 'DIE_TARGET_C=86'
assert_eq "a DIE_TARGET_C just under CRIT_C is pulled below the emergency rung too" \
  84 "$(rfield target_c <<<"$(sim "$HIGHT" ambient=25)")"

# The invariant behind both, checked across the whole ambient sweep: whenever a
# ladder is chosen, the working budget must settle the die BELOW the top rung,
# or that rung is the operating point rather than the emergency.
bad=""
for a in 5 10 15 20 25 28 30 31 32 34 40 45; do
  o=$(sim "$REF" "ambient=$a")
  [[ "$(rfield mode <<<"$o")" == ladder ]] || continue
  t=$(rfield tiers <<<"$o"); top=${t##*,}; top=${top%%:*}
  b=$(rfield budget_w <<<"$o"); r=$(rfield rtheta <<<"$o")
  awk -v a="$a" -v r="$r" -v b="$b" -v top="$top" 'BEGIN{exit !(a + r*b < top)}' \
    || bad+="ambient $a settles $(awk -v a="$a" -v r="$r" -v b="$b" 'BEGIN{printf "%.1f", a+r*b}')C vs rung ${top}C; "
done
if [[ -z "$bad" ]]
then pass "across the sweep, every generated ladder settles below its own top rung"
else fail "across the sweep, every generated ladder settles below its own top rung" "$bad"; fi

# --- ADAPTIVE=yes must never end up capping nothing ---------------------------
# A ladder the tier engine cannot run (a rung at or above Tjmax, which a CRIT_C
# taken from the ACPI trip points produces) used to leave the daemon with no
# baseline and no rungs at all.
ABOVE="$WORK/crit-above-tjmax.conf"
if (( EUID == 0 )); then
  skip "an unbuildable ladder falls through to a constant cap instead of no cap" \
       "never starting the guard loop as root"
elif (( ! TJMAX_OK )); then
  skip "an unbuildable ladder falls through to a constant cap instead of no cap" \
       "this machine's real Tjmax is not ${TJMAX}C, so the trigger temperature would differ"
else
  ABOVETRACE="$WORK/above.trace"
  mkconf "$ABOVE" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=108' \
                  'POLL_SEC=0.5' "TRACE=$ABOVETRACE" 'RESTORE_ON_EXIT=no' \
                  'DISABLE_TURBO=no' 'CRIT_ACTION=throttle-only'
  loopout=$(THERMAL_GUARD_CONFIG="$ABOVE" timeout 4 "$TG" 2>&1)
  if [[ "$loopout" == *"can neither cap power"* ]]; then
    # Correct behaviour in its own right, and the reason this one cannot be
    # asserted unprivileged: the guard loop refuses ADAPTIVE=yes when it can
    # write neither RAPL nor max_perf_pct, which unprivileged is always.
    pass "ADAPTIVE=yes refuses to start where it can act on nothing"
    skip "an unbuildable ladder falls through to a constant cap instead of no cap" \
         "needs write access to RAPL or intel_pstate, i.e. root, and this suite never runs the loop as root"
  elif [[ -s "$ABOVETRACE" ]]; then
    assert_contains "an unbuildable ladder falls through to a constant cap" \
      "$(cat "$ABOVETRACE")" "falling back to a constant cap"
    assert_not_contains "...so ADAPTIVE=yes never ends up capping nothing" \
      "$(cat "$ABOVETRACE")" "monitoring only, not capping power"
    rline=$(grep -o 'RESULT v=1.*' "$ABOVETRACE" | tail -1)
    printf '%s\n' "$rline" >> "$ALLRESULTS"
    assert_eq "...and the RESULT line describes the plan that was committed, not the rejected one" \
      constant "$(rfield mode <<<"$rline")"
    assert_eq "...with no ladder in it" "-" "$(rfield tiers <<<"$rline")"
  else
    skip "an unbuildable ladder falls through to a constant cap" \
         "no temperature sensor here, so the loop correctly refused to start"
  fi
  if [[ -e "$NETMARK" ]]; then
    fail "the ADAPTIVE=yes loop with AMBIENT_C set uses no network" "$(cat "$NETMARK")"
  else
    pass "the ADAPTIVE=yes loop with AMBIENT_C set uses no network"
  fi
fi

# --- trust in a weather reading decays with its age ---------------------------
# A reading two hours fifty-nine minutes old used to carry full weight, so a
# cold morning could fund a hot afternoon at the morning's budget.
AGED="$WORK/aged.conf"
mkconf "$AGED" 'ADAPTIVE=yes' 'PLACEMENT=outdoor' 'LOCATION=auto' \
               'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIER_HYSTERESIS=7'
NOW=$(date +%s)
prev=""; mono=1; ambs=""
for age in 60 3000 5500 8200 10500; do
  wxfile "$(printf 'temp_c=25\nfetched_at=%s\nstatus=ok\n' "$((NOW - age))")"
  o=$(detect "$AGED")
  b=$(rfield budget_w <<<"$o"); ambs+="${age}s->${b}W "
  [[ -n "$prev" ]] && { awk -v a="$b" -v p="$prev" 'BEGIN{exit !(a<=p)}' || mono=0; }
  prev=$b
done
wxfile "$(printf 'temp_c=25\nfetched_at=%s\nstatus=ok\n' "$((NOW - 60))")"
fresh_b=$(rfield budget_w <<<"$(detect "$AGED")")
wxfile "$(printf 'temp_c=25\nfetched_at=%s\nstatus=ok\n' "$((NOW - 10500))")"
old_o=$(detect "$AGED"); old_b=$(rfield budget_w <<<"$old_o")
assert_eq "an aged reading is still weather, not a silent fallback" \
  weather "$(rfield ambient_src <<<"$old_o")"
if (( mono )); then pass "the budget never rises as the reading ages ($ambs)"
else fail "the budget never rises as the reading ages" "$ambs"; fi
if awk -v a="$old_b" -v f="$fresh_b" 'BEGIN{exit !(a<f)}'
then pass "a nearly-stale reading buys strictly fewer watts than a fresh one (${old_b}W vs ${fresh_b}W)"
else fail "a nearly-stale reading buys strictly fewer watts than a fresh one" "${old_b}W vs ${fresh_b}W"; fi
assert_contains "--detect says how far the reading has aged towards the fallback" \
  "$old_o" "of the way to the"
rm -f "$STATE/weather"

# --- an explicit BUDGET_MAX_W is not clipped to a detected stock limit --------
BIGMAX="$WORK/bigmax.conf"
mkconf "$BIGMAX" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
                 'BUDGET_MAX_W=25'
assert_eq "a BUDGET_MAX_W above the detected stock limit is used as written" \
  25 "$(rfield budget_w <<<"$(sim "$BIGMAX" ambient=-60)")"
assert_contains "...and it warns, naming both numbers" "$(detect "$BIGMAX")" \
  "is what the engine uses"

# --- --detect shows the stock limit the derived values are built on -----------
assert_contains "--detect prints the detected stock power limit and where it came from" \
  "$(detect "$REF")" "stock power limit"

# --- a pinned TIERS or CLAMP_WATTS warns, not just a pinned NORMAL_WATTS ------
PINT="$WORK/pinned-tiers.conf"
mkconf "$PINT" 'ADAPTIVE=yes' 'PLACEMENT=outdoor' 'AMBIENT_C=34' \
               'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'TIERS="80:11 85:7"'
o=$(detect "$PINT")
assert_eq "a TIERS-only pin still pins the plan" pinned "$(rfield reason <<<"$o")"
assert_contains "a TIERS-only pin above the sustainable budget is warned about" \
  "$o" "rung of your pinned TIERS carries 11W"
assert_contains "...against the same 9W the engine would have chosen" "$o" "above the 9W"

PINC="$WORK/pinned-clamp.conf"
mkconf "$PINC" 'ADAPTIVE=yes' 'PLACEMENT=outdoor' 'AMBIENT_C=34' \
               'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'CLAMP_WATTS=12'
assert_contains "a CLAMP_WATTS-only pin above the sustainable budget is warned about too" \
  "$(detect "$PINC")" "CLAMP_WATTS=12 is pinned"

PINN="$WORK/pinned-normal.conf"
mkconf "$PINN" 'ADAPTIVE=yes' 'PLACEMENT=outdoor' 'AMBIENT_C=34' \
               'RTHETA_C_PER_W=5.24' 'CRIT_C=88' 'NORMAL_WATTS=11'
assert_contains "and the original NORMAL_WATTS wording is unchanged" \
  "$(detect "$PINN")" "NORMAL_WATTS=11 is pinned and is above the 9W"

# --- a rejected ladder explains itself with the term that actually caused it --
FLOORED="$WORK/floored.conf"
mkconf "$FLOORED" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' 'CRIT_C=88' \
                  'BUDGET_MIN_W=9' 'BUDGET_MAX_W=9' 'ADAPTIVE_MODE=ladder'
o=$(sim "$FLOORED" ambient=25)
assert_eq "a ladder with no step below the budget falls back to a constant cap" \
  constant "$(rfield mode <<<"$o")"
assert_contains "...and blames BUDGET_MIN_W, which is what actually caused it" \
  "$o" "floored up to BUDGET_MIN_W (9W)"
assert_not_contains "...and no longer blames the release temperature" \
  "$o" "above its own release temperature"

# --- --simulate rejects a malformed argument whether or not the engine is on --
run_tg "$EMPTY" --simulate banana >/dev/null
assert_eq "--simulate banana exits 2 with ADAPTIVE=no, not 0" 2 "$(lastrc)"
run_tg "$EMPTY" --simulate ambeint=25 >/dev/null
assert_eq "--simulate with a mistyped keyword exits 2 with ADAPTIVE=no" 2 "$(lastrc)"
run_tg "$REF" --simulate banana >/dev/null
assert_eq "--simulate banana still exits 2 with ADAPTIVE=yes" 2 "$(lastrc)"
run_tg "$EMPTY" --simulate 25 >/dev/null
assert_eq "a valid argument still succeeds with ADAPTIVE=no" 0 "$(lastrc)"

# --- uninstall --purge knows about the adaptive cache files -------------------
# Asserted against the source rather than by running it: uninstall.sh stops
# services and touches /etc, which a test suite must never do on the machine it
# is running on.
unsrc=$(cat "$ROOT/uninstall.sh")
assert_contains "uninstall.sh defines the weather cache path"  "$unsrc" 'WEATHER_FILE="$STATE_DIR/weather"'
assert_contains "uninstall.sh defines the location cache path" "$unsrc" 'LOCATION_FILE="$STATE_DIR/location"'
assert_contains "--purge removes the weather cache"            "$unsrc" '"$WEATHER_FILE"'
assert_contains "--purge removes the location cache, which holds a home address" \
  "$unsrc" '"$LOCATION_FILE"'
assert_contains "--purge reports what it could not remove instead of failing silently" \
  "$unsrc" "still contains files this uninstaller does not know about"

# ============================================================================
group "8c. RATING vs SNAPSHOT — the stale stock limit defect"
# ============================================================================
# Found in production on the reference machine. The daemon used to answer two
# different questions with one number:
#
#   "what is this CPU rated to sustain?"   -> the basis for the budget ceiling,
#                                             the idle-rise estimate, and the
#                                             engine's uncapped baseline
#   "what was in the register before us?"  -> the thing to put back on exit
#
# It answered both with a snapshot of the live register taken on the first ever
# run. On a machine whose first run happened while an earlier experiment had the
# package capped, that snapshot recorded 11 W as the rating of a 17 W part, and
# never self-corrected: the ceiling, the idle rise and the ladder's burst
# headroom were all silently held at 11 W. `--detect` reported it as stock.
SNAP="$STATE/stock-power-limit-uw"
printf '%s\n' 11000000 > "$SNAP"      # a stale snapshot, 11 W on a 17 W part

out=$(detect "$REF")
eff_ceiling=$(sed -n 's/^  budget band *: [^ ]*W \.\. \([^ ]*\)W .*/\1/p' <<<"$out")
assert_eq "a stale 11W snapshot does not become the ${CEILING}W ceiling" "$CEILING" "$eff_ceiling"

# 0.45 x 5.24 x 17 = 40.1 C of idle rise, so a 25 C ambient idles at 65.1 C.
# Derived from the stale snapshot instead it would be 0.45 x 5.24 x 11 = 25.9 C,
# an idle floor of 50.9 C — 14 C too cool, which is what made a ladder look
# viable in heat where the balcony measurement proved it is not.
assert_within "the idle-rise estimate follows the rating, not the snapshot" \
              65.1 "$(sim "$REF" ambient=25 | rfield idle_floor_c)" 0.2

# The two numbers must be visible separately, or the defect is undiagnosable.
assert_contains "--detect prints the snapshot separately when it differs from the rating" \
                "$out" "saved snapshot"
assert_contains "--detect says the snapshot is not used for budgets" \
                "$out" "NOT used for budgets"
assert_contains "--detect names the file and the remedy for a stale snapshot" \
                "$out" "stopping the service would restore 11W"

# Budgets must be completely unmoved by the stale snapshot: same ground truth.
assert_eq "ground truth A survives a stale snapshot (25C -> the shipped ladder)" \
          "80:11,85:7" "$(sim "$REF" ambient=25 | rfield tiers)"
assert_eq "ground truth B survives a stale snapshot (34C -> constant)" \
          constant "$(sim "$REF" ambient=34 | rfield mode)"

# And the noise must stop once the snapshot agrees with the rating.
printf '%s\n' "$STOCK_UW" > "$SNAP"
out=$(detect "$REF")
if grep -q "saved snapshot" <<<"$out"
then fail "no snapshot line when snapshot and rating agree" "printed anyway"
else pass "no snapshot line when snapshot and rating agree"; fi

# The uncapped baseline itself writes a power limit, so it cannot be exercised
# without RAPL and root. Assert the wiring instead of faking the hardware.
tgsrc=$(cat "$TG")
assert_contains "an engine-owned tier 0 applies the rating, not the snapshot" \
                "$tgsrc" "apply_uncapped_baseline"
assert_contains "restore-on-exit still restores the snapshot, which is its real job" \
                "$tgsrc" 'set_uw "$(<"$stock_power_file")"'
if grep -q 'ADAPTIVE_ON.*STOCK_RATING_UW\|STOCK_RATING_UW.*ADAPTIVE_ON' <<<"$tgsrc"
then pass "the rating baseline is gated on ADAPTIVE=yes, so legacy configs are untouched"
else fail "the rating baseline is gated on ADAPTIVE=yes, so legacy configs are untouched" "gate not found"; fi

# ============================================================================
group "9. RESULT line grammar — the tooling contract"
# ============================================================================
nlines=$(grep -c 'RESULT v=1' "$ALLRESULTS")
if (( nlines < 50 )); then
  fail "the suite produced enough RESULT lines to check the grammar" "only $nlines"
else
  pass "collected $nlines RESULT lines from every invocation above"
fi

want_order='v ambient_c ambient_src ambient_age_sec rtheta rtheta_src tjmax_c crit_c target_c idle_floor_c window_c window_min_c mode reason budget_w budget_src tiers clamp_w'
bad=$(awk -v want="$want_order" '
  { i = index($0, "RESULT v=1"); if (!i) next
    line = substr($0, i); n = split(line, f, " ")
    order = ""
    for (j = 2; j <= n; j++) { p = index(f[j], "="); order = order (order=="" ? "" : " ") substr(f[j], 1, p-1) }
    if (order != want) { print "field order/count wrong: " order; exit }
  }' "$ALLRESULTS")
if [[ -z "$bad" ]]
then pass "every RESULT line has the 18 spec fields, in order, with no spaces inside any value"
else fail "every RESULT line has the 18 spec fields, in order, with no spaces inside any value" "$bad"; fi

check_vocab() {        # $1 = field, $2 = space-separated allowed values
  local f=$1 allowed=" $2 " bad
  bad=$(sed -n 's/.*[[:space:]]'"$f"'=\([^ ]*\).*/\1/p' "$ALLRESULTS" | sort -u \
        | while read -r v; do [[ "$allowed" == *" $v "* ]] || printf '%s ' "$v"; done)
  if [[ -z "$bad" ]]
  then pass "$f only ever uses its closed vocabulary"
  else fail "$f only ever uses its closed vocabulary" "unexpected values: $bad"; fi
}
check_vocab ambient_src "manual weather fallback simulated none"
check_vocab rtheta_src  "config derived -"
check_vocab mode        "static constant ladder"
check_vocab reason      "adaptive-disabled pinned window-ok window-too-small mode-forced-ladder mode-forced-constant ambient-unknown ladder-cannot-release"
check_vocab budget_src  "config engine clipped-floor clipped-ceiling -"

# Nothing anywhere in this suite may ever have proposed powering the machine off.
if grep -q 'CRIT_ACTION=poweroff' "$ALLRESULTS" 2>/dev/null
then fail "no RESULT line ever mentions poweroff" "found one"
else pass "no RESULT line ever mentions poweroff"; fi

# ============================================================================
group "9c. ADAPTIVE_CLAMP_OFFSET_W — a more generous emergency clamp"
# ============================================================================
# The engine derives the emergency clamp as LADDER_TOP_FACTOR x budget, and this
# key adds watts to that. It is applied INSIDE the release bound, so what it
# cannot do is as important as what it can: it must never buy a rung that the
# machine cannot cool back out of, and it must never silently change the shape
# of the plan. Both are asserted here, alongside the arithmetic.
OFF0="$WORK/off0.conf"; mkconf "$OFF0" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' \
                                       'CRIT_C=88' 'TIER_HYSTERESIS=7' 'ADAPTIVE_CLAMP_OFFSET_W=0'
OFF1="$WORK/off1.conf"; mkconf "$OFF1" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' \
                                       'CRIT_C=88' 'TIER_HYSTERESIS=7' 'ADAPTIVE_CLAMP_OFFSET_W=1'
OFFBIG="$WORK/offbig.conf"; mkconf "$OFFBIG" 'ADAPTIVE=yes' 'AMBIENT_C=25' 'RTHETA_C_PER_W=5.24' \
                                       'CRIT_C=88' 'TIER_HYSTERESIS=7' 'ADAPTIVE_CLAMP_OFFSET_W=99'

# Default is zero, and zero is not a new code path: it must reproduce the
# ground-truth ladder byte for byte.
out=$(sim "$OFF0" ambient=25)
assert_eq "offset 0 leaves the ground-truth ladder untouched" \
          "80:11,85:7" "$(rfield tiers <<<"$out")"

out=$(sim "$OFF1" ambient=25)
assert_eq "offset +1W raises the emergency rung 7W -> 8W"  "80:11,85:8" "$(rfield tiers <<<"$out")"
assert_eq "offset +1W reports the raised clamp in clamp_w" "8"          "$(rfield clamp_w <<<"$out")"
assert_eq "offset +1W leaves the working rung alone"       "11"         "$(rfield budget_w <<<"$out")"
assert_eq "offset +1W does not change the plan shape"      ladder       "$(rfield mode <<<"$out")"
assert_eq "offset +1W does not change the plan reason"     window-ok    "$(rfield reason <<<"$out")"

# The safety property. 99W cannot be honoured: the rung would settle the die
# above its own release point and could never let go — the measured failure the
# release bound exists to prevent. It must be trimmed, not obeyed, and the
# ladder must survive rather than collapsing to a constant cap.
out=$(sim "$OFFBIG" ambient=25)
assert_eq "an impossible offset still yields a ladder, not a collapse" ladder "$(rfield mode <<<"$out")"
big_clamp=$(rfield clamp_w <<<"$out")
# release budget = (first rung 80C - hysteresis 7C - ambient 25C) / Rtheta 5.24
assert_le "the trimmed rung stays within the release budget (9.16W)" "$big_clamp" 9.16
settle=$(awk -v w="$big_clamp" 'BEGIN{printf "%.2f", 25 + 5.24*w}')
assert_le "the trimmed rung still cools back below its release point (73C)" "$settle" 73

# A constant-cap plan derives a clamp too, and the same key governs it.
outc=$(sim "$OFF0" ambient=40); outo=$(sim "$OFF1" ambient=40)
if [[ "$(rfield mode <<<"$outc")" == constant ]]; then
  d=$(awk -v a="$(rfield clamp_w <<<"$outc")" -v b="$(rfield clamp_w <<<"$outo")" 'BEGIN{printf "%.2f", b-a}')
  assert_eq "the offset reaches the constant-cap clamp as well" "1.00" "$d"
else
  skip "the offset reaches the constant-cap clamp as well" "no constant plan at 40C on this fixture"
fi

BADOFF="$WORK/badoff.conf"; mkconf "$BADOFF" 'ADAPTIVE=yes' 'ADAPTIVE_CLAMP_OFFSET_W=abc'
out=$(sim "$BADOFF" ambient=25); rc=$(lastrc)
if (( rc != 0 )) && [[ "$out" == *ADAPTIVE_CLAMP_OFFSET_W* ]]
then pass "a non-numeric offset is refused by name"
else fail "a non-numeric offset is refused by name" "rc=$rc out=[$out]"; fi

# ============================================================================
group "9b. contrib tools — the newest sample, and how old it is"
# ============================================================================
# Both reporting scripts print the most recent temperature in the trace. That
# figure is misleading without its age: a trace that stopped hours ago still has
# a newest sample, and that is the normal state in the case these tools exist for
# — a machine read after it went down. So the wording is asserted for a fresh
# trace and a stale one, and for a machine whose date(1) cannot compute the gap
# at all. Synthetic traces throughout: no daemon, no sensor, no root.
if ! date -d "@0" '+%Y-%m-%dT%H:%M:%S%:z' >/dev/null 2>&1; then
  skip "contrib tools report the newest sample and its age" \
       "building the fixture needs GNU date -d, which this machine does not have"
else
  mktrace() {          # mktrace FILE SECONDS_AGO LAST_TEMP
    local f=$1 endago=$2 last=$3 s e n
    n=$(date +%s); e=$(( n - endago ))
    printf '# %s RESULT v=1 mode=ladder budget_w=11.5 tiers=80:11.5,85:7 clamp_w=-\n' \
      "$(date -d "@$(( e - 120 ))" '+%Y-%m-%dT%H:%M:%S%:z')" > "$f"
    for (( s = e - 120; s < e; s += 2 )); do
      printf '%s,67,0\n' "$(date -d "@$s" '+%Y-%m-%dT%H:%M:%S%:z')" >> "$f"
    done
    printf '%s,%s,0\n' "$(date -d "@$e" '+%Y-%m-%dT%H:%M:%S%:z')" "$last" >> "$f"
  }

  FRESH="$WORK/trace-fresh.log"; mktrace "$FRESH" 4     71
  STALE="$WORK/trace-stale.log"; mktrace "$STALE" 11040 66     # stopped 3h04m back

  out=$("$ROOT/contrib/thermal-summary.sh" 1 -f "$FRESH" 2>&1)
  assert_contains "thermal-summary prints the newest temperature"        "$out" "temps  : now 71C ("
  assert_contains "thermal-summary prints how old that reading is"       "$out" "ago)"

  out=$("$ROOT/contrib/thermal-clamps.sh" 1 -f "$FRESH" 2>&1)
  assert_contains "thermal-clamps prints the newest temperature"         "$out" "latest       : 71C   (last sample, "

  # The word carries the claim: on a trace that stopped hours ago, nothing may
  # call itself "now". This is the assertion that matters after a power cut.
  out=$("$ROOT/contrib/thermal-summary.sh" 24 -f "$STALE" 2>&1)
  assert_contains     "a stale trace is reported as 'last', not 'now'"   "$out" "temps  : last 66C ("
  assert_not_contains "a stale trace never calls its newest sample 'now'" "$out" "temps  : now"

  # No date -d: print the absolute clock time rather than invent an interval.
  NODATE="$WORK/nodate"; mkdir -p "$NODATE"
  REALDATE=$(command -v date)
  cat > "$NODATE/date" <<EOF
#!/bin/sh
# Test stub: a date(1) with no -d support, as on a busybox userland.
case "\$1" in -d) exit 1 ;; esac
exec "$REALDATE" "\$@"
EOF
  chmod +x "$NODATE/date"
  out=$(PATH="$NODATE:$PATH" "$ROOT/contrib/thermal-summary.sh" 1 -f "$FRESH" 2>&1)
  assert_contains "without date -d, thermal-summary prints a clock time not a guess" \
                  "$out" "temps  : last 71C (at "
fi

# ============================================================================
group "10. hermeticity — the whole suite, end to end"
# ============================================================================
if [[ -e "$NETMARK" ]]; then
  fail "not one byte left this machine during the entire suite" "$(sort -u "$NETMARK" | head -5)"
else
  pass "not one byte left this machine during the entire suite (curl/wget stubs never invoked)"
fi
if [[ -e "$STATE/weather" || -e "$STATE/location" ]]; then
  fail "no cache file was left behind by a read-only mode" "$(ls "$STATE")"
else
  pass "--detect and --simulate never wrote a cache file"
fi

# ----------------------------------------------------------------- summary ---
printf '\n'
printf '=========================================================\n'
printf '  passed  %d\n' "$PASS"
printf '  failed  %d\n' "$FAIL"
printf '  skipped %d\n' "$SKIPPED"
printf '=========================================================\n'
if (( FAIL )); then
  printf '\nfailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
