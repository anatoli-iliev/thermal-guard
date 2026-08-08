#!/bin/bash
# thermal-clamps — what the last hour looked like: temperatures, and every clamp
# episode with how long it lasted.
#
# SPDX-FileCopyrightText: 2026 Anatoli Iliev
# SPDX-License-Identifier: MIT
#
# usage: thermal-clamps.sh [trace-file] [hours] [warn_c] [crit_c]
#        thermal-clamps.sh                     # last hour of the default trace
#        thermal-clamps.sh "" 6                # last six hours
#        thermal-clamps.sh "" 1 85 88          # thresholds matching your config
#
# A "clamp episode" is an unbroken run of samples with the clamped flag set —
# i.e. one continuous stretch during which the guard held the CPU above its
# baseline tier. Ten separate one-second dips and one ten-second hold are very
# different things, and the count alone cannot tell them apart, so this reports
# each episode's duration rather than just how many samples were clamped.
#
# Durations come from the timestamps, not from a sample count multiplied by an
# assumed POLL_SEC: the daemon can be restarted with a different interval, and a
# laptop can suspend mid-episode. What is reported is wall-clock elapsed.

set -uo pipefail

T=${1:-/var/log/thermal-trace.log}
[[ -z "$T" ]] && T=/var/log/thermal-trace.log
HOURS=${2:-1}
WARN_C=${3:-80}
CRIT_C=${4:-85}

[[ -r "$T" ]] || { echo "thermal-clamps: cannot read $T" >&2; exit 1; }
case "$HOURS" in ''|*[!0-9.]*) echo "thermal-clamps: hours must be a number (got '$HOURS')" >&2; exit 2 ;; esac

# Window selection by timestamp rather than by sample count, so a gap — the
# daemon stopped, the machine asleep — does not silently widen the window into
# yesterday. ISO-8601 with a fixed offset sorts lexicographically, so a string
# compare is exact and needs no date parsing inside awk (mawk has no mktime).
# The one case this gets wrong is a DST change inside the window.
# Converted to whole seconds first: `date -d "0.5 hours ago"` is not something GNU
# date accepts, and a fractional window is exactly what you want when chasing a
# clamp that just happened.
SECS=$(awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}')
(( SECS > 0 )) || { echo "thermal-clamps: hours must be greater than zero (got '$HOURS')" >&2; exit 2; }
CUTOFF=$(date -d "$SECS seconds ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) \
  || { echo "thermal-clamps: date(1) does not support -d; GNU coreutils is required" >&2; exit 1; }

printf '== thermal-guard: last %sh of %s ==\n' "$HOURS" "$T"
printf 'window : since %s\n' "${CUTOFF/T/ }"

# The live register, when this is the machine the trace came from. Reported on its
# own labelled line and never merged with the trace-derived figures: analysing a
# trace copied from another box is a supported use, and silently presenting THIS
# machine's watts as that machine's would be a lie in exactly the situation where
# someone is trying to work out what killed something.
LIVE_W=""
for d in /sys/class/powercap/intel-rapl:*; do
  [[ -r "$d/name" && -r "$d/constraint_0_power_limit_uw" ]] || continue
  [[ "$(<"$d/name")" == package-0 ]] || continue
  LIVE_W=$(awk -v u="$(<"$d/constraint_0_power_limit_uw")" 'BEGIN{printf "%.1f", u/1000000}')
  break
done

awk -F, -v cut="$CUTOFF" -v warn="$WARN_C" -v crit="$CRIT_C" -v live="$LIVE_W" '
  function fmt(s,   h, m) {
    if (s < 60)   return sprintf("%ds", s)
    if (s < 3600) { m = int(s/60); return sprintf("%dm%02ds", m, s-m*60) }
    h = int(s/3600); m = int((s-h*3600)/60)
    return sprintf("%dh%02dm", h, m)
  }
  # Seconds-of-day, carried across midnight by a running day offset. Only
  # differences are ever used, so the absolute origin does not matter.
  function absec(ts,   tp, p, sod) {
    tp = substr(ts, 12, 8)
    split(tp, p, ":")
    sod = (p[1]+0)*3600 + (p[2]+0)*60 + (p[3]+0)
    if (seen && sod < prev_sod - 43200) day += 86400
    prev_sod = sod; seen = 1
    return sod + day
  }
  # Event lines carry the power. They are read for state even when they fall
  # outside the window, because what was applied entering the window was decided
  # before it — dropping them would leave the first episode with no wattage.
  /^#/ {
    if ($0 ~ / TIER | CLAMP /) {
      if      (match($0, /-> stock/))    applied = "stock"
      else if (match($0, /-> [0-9.]+W/)) applied = substr($0, RSTART+3, RLENGTH-3)
    }
    if ($0 ~ / RESULT /) {
      if (match($0, /mode=[^ ]+/))    p_mode   = substr($0, RSTART+5,  RLENGTH-5)
      if (match($0, /budget_w=[^ ]+/))p_budget = substr($0, RSTART+9,  RLENGTH-9)
      if (match($0, /tiers=[^ ]+/))   p_tiers  = substr($0, RSTART+6,  RLENGTH-6)
      if (match($0, /clamp_w=[^ ]+/)) p_clamp  = substr($0, RSTART+8,  RLENGTH-8)
    }
    next
  }
  NF != 3 { next }                      # 1.0.x space-separated traces
  substr($1, 1, 19) < cut { next }      # outside the window
  {
    t = $2 + 0; c = $3 + 0; a = absec($1)
    n++
    if (n == 1) { first = a; tmin = t; tmax = t }
    last = a; lastt = $1
    sum += t
    if (t < tmin) tmin = t
    if (t > tmax) tmax = t
    if (t >= warn) nwarn++
    if (t >= crit) ncrit++

    # An episode ends at the first UNCLAMPED sample, and that timestamp is the
    # end: the clamp was in force for the whole interval it closes. Adding a
    # further sample interval on top would double-count it.
    if (c && !inrun) { inrun = 1; rs = a; rstart = substr($1, 12, 8); rpeak = t; rw = applied }
    else if (c)      { if (t > rpeak) rpeak = t }
    else if (inrun)  { inrun = 0; ne++; es[ne] = rs; ee[ne] = a; ep[ne] = rpeak; et[ne] = rstart; ew[ne] = rw }
  }
  END {
    if (!n) { print "\nno samples in this window — was the daemon running?"; exit }
    span = last - first
    step = (n > 1) ? span / (n - 1) : 2          # observed sample interval
    # An episode still open at the end of the window has no closing sample, so
    # it is credited to the end of the interval its last sample covers.
    if (inrun) { ne++; es[ne] = rs; ee[ne] = last + step; ep[ne] = rpeak; et[ne] = rstart; ew[ne] = rw; open = 1 }

    printf "samples: %d over %s (%.1fs apart)\n", n, fmt(span + step), step

    printf "\npower\n"
    if (live != "")     printf "  applied now  : %sW   (live RAPL register on THIS machine)\n", live
    if (applied != "")  printf "  last applied : %s   (from the tier events in the trace)\n", \
                                (applied == "stock" ? "stock, no cap" : applied)
    if (p_mode != "")   printf "  plan         : %s%s\n", p_mode, \
                                (p_budget != "" && p_budget != "-" ? ", budget " p_budget "W" : "")
    if (p_tiers != "" && p_tiers != "-") {
      n_t = split(p_tiers, tt, ",")
      steps = "baseline stock (uncapped)"
      for (j = 1; j <= n_t; j++) { split(tt[j], kv, ":"); steps = steps "  ->  " kv[1] "C: " kv[2] "W" }
      printf "  ladder steps : %s\n", steps
    } else if (p_clamp != "" && p_clamp != "-") {
      printf "  ladder steps : none — constant cap, emergency clamp %sW\n", p_clamp
    }

    printf "\ntemperature\n"
    printf "  min %.0fC   mean %.1fC   max %.0fC\n", tmin, sum/n, tmax
    printf "  at or above %dC : %s (%.1f%%)\n", warn, fmt(nwarn*step), 100*nwarn/n
    printf "  at or above %dC : %s (%.1f%%)\n", crit, fmt(ncrit*step), 100*ncrit/n

    if (!ne) { printf "\nclamp episodes: none — the guard never left its baseline tier\n"; exit }

    tot = 0
    for (i = 1; i <= ne; i++) { d[i] = ee[i] - es[i]; tot += d[i] }
    printf "\nclamp episodes: %d   total %s (%.1f%% of the window)\n", ne, fmt(tot), 100*tot/(span+step)
    printf "  %-3s %-10s %-9s %-6s %s\n", "#", "started", "lasted", "peak", "held at"
    for (i = 1; i <= ne; i++)
      printf "  %-3d %-10s %-9s %-6s %s%s\n", i, et[i], fmt(d[i]), sprintf("%.0fC", ep[i]),
             (ew[i] == "" ? "?" : ew[i]),
             (open && i == ne) ? "   (still clamped)" : ""

    longest = d[1]; shortest = d[1]
    for (i = 2; i <= ne; i++) { if (d[i] > longest) longest = d[i]; if (d[i] < shortest) shortest = d[i] }
    printf "  longest %s, shortest %s, mean %s\n", fmt(longest), fmt(shortest), fmt(tot/ne)
  }' "$T"
