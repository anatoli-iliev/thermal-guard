#!/bin/bash
# thermal-summary — a one-screen answer to "what has thermal-guard been doing?"
#
# SPDX-FileCopyrightText: 2026 Anatoli Iliev
# SPDX-License-Identifier: MIT
#
# usage: thermal-summary.sh [HOURS] [-f FILE]
#
#        thermal-summary.sh              # the last 24 hours
#        thermal-summary.sh 1            # the last hour
#        thermal-summary.sh 24 -f /mnt/rescued-trace.log
#
# Same argument shape as thermal-clamps.sh: the window is what you change, so it
# is the first positional and the file lives behind -f. The old "[file] [hours]"
# order still parses.
#
# Reads only the trace, so it works on a machine where the daemon is not running,
# on a copy of a trace taken from somewhere else, and — the case it is really for
# — after a power cut, when the trace is the only witness left.
#
# The `NF==3` guard is what separates sample lines from `#` event lines. It also
# skips traces written by 1.0.x, whose samples were space-separated.

set -uo pipefail

PROG=${0##*/}
T=""; HOURS=""

usage() {
  cat <<EOF
usage: $PROG [HOURS] [-f FILE]

  HOURS        how far back to look, decimals allowed (default 24)
  -f, --file   trace to read (default /var/log/thermal-trace.log)
  -h, --help   this
EOF
}

is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

while (( $# )); do
  case "$1" in
    -f|--file) [[ $# -ge 2 ]] || { echo "$PROG: $1 needs a value" >&2; exit 2; }; T=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        echo "$PROG: unknown option $1 (try --help)" >&2; exit 2 ;;
    *)
      if is_num "$1"; then
        [[ -z "$HOURS" ]] || { echo "$PROG: more than one duration given (try --help)" >&2; exit 2; }
        HOURS=$1
      else
        [[ -z "$T" ]] || { echo "$PROG: more than one trace given (try --help)" >&2; exit 2; }
        T=$1
      fi
      shift ;;
  esac
done

T=${T:-/var/log/thermal-trace.log}
HOURS=${HOURS:-24}

if [[ ! -r "$T" ]]; then
  echo "$PROG: cannot read $T" >&2
  [[ "$T" =~ ^[0-9.]+[A-Za-z]+$ ]] && echo "$PROG: for a duration, give a bare number of hours: $PROG ${T%%[A-Za-z]*}" >&2
  exit 1
fi
is_num "$HOURS" || { echo "$PROG: hours must be a number (got '$HOURS')" >&2; exit 2; }

# 2 s is the default POLL_SEC. If yours differs the window is scaled wrong, which
# is why the sample count is printed rather than assumed. Computed in awk because
# bash arithmetic is integer-only and fractional windows are useful.
SAMPLES=$(awk -v h="$HOURS" 'BEGIN{printf "%d", h*1800}')
(( SAMPLES > 0 )) || { echo "$PROG: hours must be greater than zero (got '$HOURS')" >&2; exit 2; }

printf '== thermal-guard: last %sh of %s ==\n' "$HOURS" "$T"

active=$(grep '^# .* RESULT ' "$T" | tail -1)
if [[ -n "$active" ]]; then
  printf 'active : %s\n' "${active#\# }"
else
  printf 'active : no RESULT line — adaptive is off, or this trace predates 1.2.0\n'
fi

# Labelled as this machine, never merged with the trace-derived numbers: reading a
# trace copied from another box is a supported use.
for d in /sys/class/powercap/intel-rapl:*; do
  [[ -r "$d/name" && -r "$d/constraint_0_power_limit_uw" ]] || continue
  [[ "$(<"$d/name")" == package-0 ]] || continue
  printf 'power  : %sW applied right now (live RAPL on THIS machine)\n' \
    "$(awk -v u="$(<"$d/constraint_0_power_limit_uw")" 'BEGIN{printf "%.1f", u/1000000}')"
  break
done

# How old the newest sample is. The temperature on its own is not worth much
# without it: a trace that stopped three hours ago still has a newest sample, and
# printing that as the current temperature is exactly how a post-mortem reading
# gets mistaken for a live one — in the case this tool is really for, a power cut,
# that is the default outcome. GNU date parses the offset the timestamps already
# carry; where `date -d` is missing the absolute clock time is printed instead,
# because a wrong interval is worse than no interval.
AGE_S=-1; AGE_ABS=""
last_line=$(grep -v '^#' "$T" | awk -F, 'NF==3' | tail -1)
if [[ -n "$last_line" ]]; then
  last_ts=${last_line%%,*}
  AGE_ABS=${last_ts:11:8}
  if now_s=$(date +%s 2>/dev/null) && then_s=$(date -d "$last_ts" +%s 2>/dev/null); then
    AGE_S=$(( now_s - then_s ))
    (( AGE_S < 0 )) && AGE_S=0        # clock skew, or a trace written in the future
  fi
fi

grep -v '^#' "$T" | awk -F, 'NF==3' | tail -"$SAMPLES" |
  awk -F, -v age_s="$AGE_S" -v age_abs="$AGE_ABS" '
    # Same shape as thermal-clamps.sh, so the two tools read alike.
    function fmt(s,   h, m) {
      if (s < 60)   return sprintf("%ds", s)
      if (s < 3600) { m = int(s/60); return sprintf("%dm%02ds", m, s-m*60) }
      h = int(s/3600); m = int((s-h*3600)/60)
      return sprintf("%dh%02dm", h, m)
    }
    { n++; c += $3; t = $2 + 0; s += t; t_last = t
      if (t > max) max = t
      if (t >= 85) hot++ }
    END {
      if (!n) { print "temps  : no sample lines in this trace"; exit }
      # "now" is a claim about currency, so it is only made when the sample is
      # recent — 60s is 30 missed polls at the default 2s interval. Past that the
      # word itself changes rather than leaving the age to be read carefully.
      if (age_s >= 0) { lbl = (age_s <= 60 ? "now" : "last"); ago = fmt(age_s) " ago" }
      else            { lbl = "last"; ago = "at " age_abs }
      printf "temps  : %s %.0fC (%s)  mean %.1fC  peak %.0fC  %.1f%% clamped  (%d samples)\n",
             lbl, t_last, ago, s/n, max, 100*c/n, n
      printf "hot    : %d samples at or above 85C%s\n",
             hot, (hot ? "  <- check what your machine actually misbehaves at" : "")
    }'

# The AMBIENT line reports the value the engine used AND, in parentheses, the raw
# reading it was derived from. Those differ once a reading starts ageing toward the
# fallback, and printing only one of them makes the budget look arbitrary.
amb=$(grep '^# .* AMBIENT ' "$T" | tail -1)
[[ -n "$amb" ]] && printf 'outside: %s\n' "${amb#*AMBIENT }"

printf 'plans  : %s change(s), %s ambient fallback(s)\n' \
  "$(grep -c '^# .* PLAN ' "$T")" \
  "$(grep '^# .* AMBIENT ' "$T" | grep -c fallback)"

# Anything that took performance away is worth surfacing without being asked.
warns=$(grep '^# .*warning: PLAN ' "$T" | tail -3)
[[ -n "$warns" ]] && printf 'recent warnings:\n%s\n' "$warns"

exit 0
