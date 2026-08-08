#!/bin/bash
# thermal-summary — a one-screen answer to "what has thermal-guard been doing?"
#
# SPDX-FileCopyrightText: 2026 Anatoli Iliev
# SPDX-License-Identifier: MIT
#
# usage: thermal-summary.sh [trace-file] [hours]
#
# Reads only the trace, so it works on a machine where the daemon is not running,
# on a copy of a trace taken from somewhere else, and — the case it is really for
# — after a power cut, when the trace is the only witness left.
#
# The `NF==3` guard is what separates sample lines from `#` event lines. It also
# skips traces written by 1.0.x, whose samples were space-separated.

set -uo pipefail

T=${1:-/var/log/thermal-trace.log}
HOURS=${2:-24}

[[ -r "$T" ]] || { echo "thermal-summary: cannot read $T" >&2; exit 1; }

# 2 s is the default POLL_SEC. If yours differs the window is scaled wrong, which
# is why the sample count is printed rather than assumed.
SAMPLES=$(( HOURS * 1800 ))

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

grep -v '^#' "$T" | awk -F, 'NF==3' | tail -"$SAMPLES" |
  awk -F, '
    { n++; c += $3; t = $2 + 0; s += t
      if (t > max) max = t
      if (t >= 85) hot++ }
    END {
      if (!n) { print "temps  : no sample lines in this trace"; exit }
      printf "temps  : mean %.1fC  peak %.0fC  %.1f%% clamped  (%d samples)\n",
             s/n, max, 100*c/n, n
      printf "hot    : %d samples at or above 85C%s\n",
             hot, (hot ? "  <- check what your machine actually misbehaves at" : "")
    }'

printf 'plans  : %s change(s), %s ambient fallback(s)\n' \
  "$(grep -c '^# .* PLAN ' "$T")" \
  "$(grep '^# .* AMBIENT ' "$T" | grep -c fallback)"

# Anything that took performance away is worth surfacing without being asked.
warns=$(grep '^# .*warning: PLAN ' "$T" | tail -3)
[[ -n "$warns" ]] && printf 'recent warnings:\n%s\n' "$warns"

exit 0
