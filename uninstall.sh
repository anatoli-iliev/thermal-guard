#!/bin/bash
# thermal-guard uninstaller.  sudo ./uninstall.sh [--purge]
# SPDX-License-Identifier: MIT
#
# READ THIS: stopping the service is NOT enough on its own.
#
# thermal-guard writes the CPU power limit and the turbo flag directly into
# hardware registers. Those values PERSIST after the process exits — they only
# clear on a full power cycle. So `systemctl stop thermal-guard` leaves your CPU
# capped at whatever was last set, with no running service to explain why.
#
# This script restores the stock power limit that was saved the first time the
# guard ran (/var/lib/thermal-guard/stock-power-limit-uw), so it puts back YOUR
# machine's real value rather than a hardcoded guess.
#
#   --purge   also remove /etc/thermal-guard.conf, the saved state and the trace

set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./uninstall.sh"; exit 1; }

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

PREFIX=${PREFIX:-/usr/local}
BIN="$PREFIX/bin/thermal-guard"
CONF=/etc/thermal-guard.conf
UNIT=/etc/systemd/system/thermal-guard.service
STATE_DIR=/var/lib/thermal-guard
STOCK_FILE="$STATE_DIR/stock-power-limit-uw"
TURBO_FILE="$STATE_DIR/stock-no-turbo"
PERF_FILE="$STATE_DIR/stock-max-perf-pct"
PSTATE=/sys/devices/system/cpu/intel_pstate
TRACE=/var/log/thermal-trace.log
[[ -r "$CONF" ]] && TRACE=$(. "$CONF" 2>/dev/null; echo "${TRACE:-/var/log/thermal-trace.log}")

find_rapl_package() {
  local d
  for d in /sys/class/powercap/intel-rapl:*; do
    [[ -r "$d/name" ]] || continue
    [[ "$(<"$d/name")" == "package-0" ]] && { echo "$d"; return 0; }
  done
  for d in /sys/class/powercap/intel-rapl:*; do
    [[ -d "$d" && -r "$d/constraint_0_power_limit_uw" ]] && { echo "$d"; return 0; }
  done
  return 1
}
RAPL=$(find_rapl_package) || RAPL=""

echo "=== 1/4  stop and disable the service ==="
if [[ -d /run/systemd/system ]]; then
  systemctl disable --now thermal-guard >/dev/null 2>&1 && echo "   stopped and disabled" || echo "   was not running"
else
  echo "   no systemd; kill the process yourself if it is running"
fi

echo "=== 2/4  RESTORE the stock hardware state ==="
# The guard normally restores these itself on SIGTERM. This is the belt-and-braces
# path for when it was SIGKILLed, crashed, or the machine lost power mid-clamp.
if [[ -n "$RAPL" && -w "$RAPL/constraint_0_power_limit_uw" ]]; then
  if [[ -r "$STOCK_FILE" ]]; then
    want=$(<"$STOCK_FILE")
    printf '%s\n' "$want" > "$RAPL/constraint_0_power_limit_uw" 2>/dev/null
    got=$(<"$RAPL/constraint_0_power_limit_uw")
    printf '   power limit -> %s W (saved stock value)\n' "$(( want / 1000000 ))"
    [[ "$got" != "$want" ]] && echo "   WARNING: the write did not take; a full power cycle will clear it"
  else
    echo "   NO SAVED STOCK VALUE at $STOCK_FILE"
    echo "   Not guessing your original limit. Current limit is $(( $(<"$RAPL/constraint_0_power_limit_uw") / 1000000 )) W."
    echo "   A full power cycle (shut down, not reboot) restores the firmware default."
  fi
else
  echo "   RAPL absent or not writable; nothing to restore"
fi

# Restore the ORIGINAL turbo / perf values, not assumed ones — someone may have
# deliberately had turbo off before thermal-guard was ever installed.
if [[ -w "$PSTATE/no_turbo" ]]; then
  if [[ -r "$TURBO_FILE" ]]; then
    printf '%s\n' "$(<"$TURBO_FILE")" > "$PSTATE/no_turbo" 2>/dev/null \
      && printf '   no_turbo -> %s (saved original)\n' "$(<"$TURBO_FILE")"
  else
    echo 0 > "$PSTATE/no_turbo" 2>/dev/null && echo "   no_turbo -> 0 (turbo enabled; no saved value)"
  fi
fi
if [[ -w "$PSTATE/max_perf_pct" ]]; then
  if [[ -r "$PERF_FILE" ]]; then
    printf '%s\n' "$(<"$PERF_FILE")" > "$PSTATE/max_perf_pct" 2>/dev/null \
      && printf '   max_perf_pct -> %s (saved original)\n' "$(<"$PERF_FILE")"
  else
    echo 100 > "$PSTATE/max_perf_pct" 2>/dev/null && echo "   max_perf_pct -> 100 (no saved value)"
  fi
fi

echo "=== 3/4  remove files ==="
for f in "$UNIT" "$BIN"; do
  [[ -e "$f" ]] && { rm -f "$f"; echo "   removed $f"; }
done
[[ -d /run/systemd/system ]] && systemctl daemon-reload
if (( PURGE )); then
  for f in "$CONF" "$STOCK_FILE" "$TURBO_FILE" "$PERF_FILE" "$TRACE" "$TRACE.1"; do
    [[ -e "$f" ]] && { rm -f "$f"; echo "   removed $f"; }
  done
  rmdir "$STATE_DIR" 2>/dev/null
else
  echo "   kept $CONF, the saved state in $STATE_DIR and $TRACE"
  echo "   (use --purge to remove those too)"
fi

echo "=== 4/4  thermald ==="
if [[ -d /run/systemd/system ]] && systemctl list-unit-files thermald.service &>/dev/null; then
  if systemctl is-enabled --quiet thermald 2>/dev/null; then
    echo "   thermald already enabled"
  else
    systemctl enable --now thermald >/dev/null 2>&1 \
      && echo "   thermald re-enabled and started" \
      || echo "   could not start thermald (check: systemctl status thermald)"
  fi
else
  echo "   thermald not present"
fi

echo
echo "================ VERIFICATION ================"
[[ -e "$BIN" ]] && echo "binary        : STILL PRESENT" || echo "binary        : removed"
if [[ -n "$RAPL" && -r "$RAPL/constraint_0_power_limit_uw" ]]; then
  printf 'power limit   : %s W\n' "$(( $(<"$RAPL/constraint_0_power_limit_uw") / 1000000 ))"
fi
[[ -r "$PSTATE/no_turbo" ]]     && printf 'turbo enabled : %s\n' "$([[ $(<"$PSTATE/no_turbo") == 0 ]] && echo yes || echo NO)"
[[ -r "$PSTATE/max_perf_pct" ]] && printf 'max_perf_pct  : %s\n' "$(<"$PSTATE/max_perf_pct")"
echo "=============================================="
echo
echo "The power cap is gone. If you installed thermal-guard because your machine"
echo "was shutting down under load, that condition is now back."
