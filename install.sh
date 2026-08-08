#!/bin/bash
# thermal-guard installer.  sudo ./install.sh
# SPDX-FileCopyrightText: 2026 Anatoli Iliev
# SPDX-License-Identifier: MIT
#
# Installs in monitor-only mode: nothing is capped and nothing is shut down until
# you set NORMAL_WATTS in /etc/thermal-guard.conf. Safe to run and walk away.

set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=${PREFIX:-/usr/local}
BIN="$PREFIX/bin/thermal-guard"
CONF=/etc/thermal-guard.conf
UNIT=/etc/systemd/system/thermal-guard.service

echo "=== 1/4  install the binary ==="
install -Dm0755 "$SRC/thermal-guard" "$BIN"
echo "   $BIN"

echo "=== 2/4  install the config ==="
if [[ -e "$CONF" ]]; then
  echo "   $CONF already exists — keeping your settings"
  echo "   (to adopt new defaults: cp $SRC/thermal-guard.conf.example $CONF)"
else
  install -Dm0644 "$SRC/thermal-guard.conf.example" "$CONF"
  echo "   $CONF  (everything commented out = monitor-only)"
fi

echo "=== 3/4  install the systemd unit ==="
if [[ -d /run/systemd/system ]]; then
  install -Dm0644 "$SRC/systemd/thermal-guard.service" "$UNIT"
  systemctl daemon-reload
  # thermald also drives intel_pstate max_perf_pct; two daemons on one knob is a
  # bad time. Only disable it if the user is actually going to cap something.
  if systemctl is-active --quiet thermald 2>/dev/null; then
    echo "   NOTE: thermald is running. The unit declares Conflicts=thermald.service,"
    echo "         so starting thermal-guard will stop thermald. If you would rather"
    echo "         keep thermald, remove that line from $UNIT and use CRIT_ACTION=log-only."
  fi
  systemctl enable thermal-guard >/dev/null 2>&1
  systemctl restart thermal-guard
  echo "   enabled and started"
else
  echo "   no systemd detected — run '$BIN' yourself, or add it to your init system"
fi

echo "=== 4/4  what was detected on this machine ==="
echo
DETECT=$("$BIN" --detect 2>&1) || true
printf '%s\n' "$DETECT" | sed 's/^/   /'

echo
echo "=============================================================="
# This banner used to assert monitor-only unconditionally, which is false on any
# upgrade over an existing config — and false in the worst direction, telling
# someone their CPU is unguarded while it is in fact being capped. Read the
# effective configuration back out of --detect rather than asserting it.
if printf '%s\n' "$DETECT" | grep -q 'Nothing will be capped'; then
  echo "Installed in MONITOR-ONLY mode. Nothing is capped yet."
  echo
  echo "To opt in to a power cap, edit $CONF, set NORMAL_WATTS, then:"
  echo "   sudo systemctl restart thermal-guard"
else
  echo "Installed, and ENFORCING the configuration shown above."
  echo
  echo "To change it, edit $CONF, then:"
  echo "   sudo systemctl restart thermal-guard"
fi
echo
echo "Watch it:      journalctl -fu thermal-guard"
echo "Temperatures:  tail -f /var/log/thermal-trace.log"
echo "Re-check:      thermal-guard --detect"
echo "=============================================================="
