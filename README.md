# thermal-guard

**Your laptop shuts off under load, with nothing in the logs. This finds out why, and stops it.**

[![CI](https://github.com/anatoli-iliev/thermal-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/anatoli-iliev/thermal-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25)
![Platform](https://img.shields.io/badge/platform-Linux-blue)

thermal-guard keeps a CPU inside a thermal envelope it can actually sustain, and
records what happened if the machine dies anyway.

**Safe by default.** Installing changes nothing about how your machine runs. It
monitors and records. Capping is something you opt into, after you have data.

---

## The problem

Your laptop dies under sustained load. Instantly — no shutdown, no blue screen, no
kernel panic. You check the logs and find:

```
$ journalctl -b -1 -n 5
... sysstat-collect.service: Deactivated successfully.
... Finished sysstat-collect.service - system activity accounting tool.
<end of file>
```

The log just *stops*. There is nothing to diagnose, because **power was cut below the
operating system.** The kernel never knew.

It gets worse. Many laptop boards set their thermal trip points *above* the CPU's own
limit:

```bash
$ cat /sys/class/hwmon/hwmon*/temp1_crit          # 105000  <- Tjmax, the CPU's limit
$ cat /sys/class/thermal/thermal_zone0/trip_point_*_temp   # 108000, 110000
```

Those trip points are what the kernel uses for its graceful thermal shutdown. Set
above Tjmax, they are **unreachable** — the hardware always acts first. So you never
get a clean shutdown and a warning. You get a power cut and lose your work.

thermal-guard does three things about this:

| | |
|---|---|
| 📉 **Caps sustained CPU power** | so the die never reaches the temperature where your machine gives up |
| 🛑 **Clamps hard** | if it climbs anyway |
| 💾 **Records everything, fsynced** | so a power cut still leaves you the temperatures and watts from the seconds before |

That last one is often the most valuable. It turns *"it randomly dies"* into a
measurement.

---

## Real-world case study

This tool exists because of one specific laptop. The numbers below are all measured.

**ASUS VivoBook S550CA** — Intel i5-3317U, 2 cores / 4 threads, 17 W TDP, built 2012.
It had been dying under load for two weeks: **12 abrupt power cuts in 13 days**, always
after 3–5 minutes of a parallel dev workload. Nothing in the logs, ever.

### What the trace revealed

Once thermal-guard was recording, the next crash produced this — the final samples
before power was cut:

```
timestamp            die   package   cpu    throttle events
16:23:22             90°C  11.52 W   93%    562
16:23:24             90°C  11.61 W   92%    568
16:23:26             91°C  11.89 W   95%    572
16:23:29             90°C  13.84 W   93%    574
16:23:31             91°C  11.79 W   94%    576
16:23:33             91°C  11.43 W   91%    580
<power cut>
```

Two facts jumped out:

**1. It died at 91 °C — but Tjmax is 105 °C.** Something was removing power 14 °C
below the CPU's own limit. Across three recorded crashes the death temperature was
always **89–92 °C**, at different power levels and different battery states. A trip
that tracks *temperature* rather than *current* — so not a power-delivery fault.

**2. The CPU was only drawing 12.33 W of its 17 W rating.** The machine could not
sustain even two-thirds of its rated power without reaching the temperature that
killed it.

Everything else was ruled out with data: no kernel panic, no machine-check exception,
memory at 24–26% with swap untouched (not OOM), on mains at 99% (not the battery),
identical power limits on AC and DC.

### What was wrong

Measuring **thermal resistance** — how many degrees the die rises per watt — gave
`5.24 °C/W`, against roughly `3.53 °C/W` for a healthy design of that class. **Cooling
at about two-thirds of spec**, on a 13-year-old laptop that had never been opened.

The fan told the same story from a different angle. A fan stepping up shows as a
sudden temperature drop at constant load. Below 85 °C there were 6 clear steps of
3–6 °C. **Above 88 °C, across 238 samples, there were none.** The fan was at maximum
with nothing left to give.

### What fixed it

Capping sustained package power to **10 W**:

| | Uncapped | Capped to 10 W |
|---|---|---|
| Mean frequency under load | 2394 MHz | **1924 MHz** |
| Performance | 100% | **80%** |
| Die temperature | 89–92 °C | **~76 °C** |
| Outcome | **died 3× in one afternoon** | **survived the same workload** |

**80% of the performance, and it stopped dying.** Raising to 11 W bought back most of
the rest — about 89% — while staying 6 °C below the death floor. Peak frequency stays
at 2394 MHz even when capped, because only the *sustained* budget is limited, so
interactive responsiveness barely changes.

That configuration ships as [`examples/asus-s550ca.conf`](examples/asus-s550ca.conf),
with every number annotated. **Copy the method, not the numbers.**

---

## Quick start

```bash
git clone https://github.com/anatoli-iliev/thermal-guard
cd thermal-guard
sudo ./install.sh
```

Then see what your hardware can do:

```bash
thermal-guard --detect
```

```
thermal-guard 1.0.0 — detected configuration

hardware
  temperature source : /sys/class/thermal/thermal_zone7/temp
  Tjmax              : 105C
  RAPL package       : /sys/class/powercap/intel-rapl:0
  current power limit: 17.0W
  can cap power      : yes
  intel_pstate       : available
  current temp       : 71C
...
  No power budget set, so nothing will be capped. This is the default.
```

At this point it is only watching. Nothing about your machine has changed.

---

## Choosing a power budget

This is the one decision that matters. There is no universal right answer — it depends
on your chassis, your ambient temperature and how bad your cooling is.

**1. Find out what "normal" looks like.** Let it record while you work for a day:

```bash
tail -f /var/log/thermal-trace.log
```

**2. Pick a starting budget.** `--detect` shows your stock limit. If you are trying to
stop thermal shutdowns, start at roughly **60% of stock**:

```bash
sudo nano /etc/thermal-guard.conf     # set NORMAL_WATTS=10
sudo systemctl restart thermal-guard
```

**3. Run a real sustained workload for 15–20 minutes.** Compile something big, run your
full test suite — whatever was killing it.

**4. Climb.** If it survives, raise by 1 W and repeat. If it dies, or the clamp keeps
engaging, go back a step. Frequency scales close to linearly with power over the useful
range, so each watt is worth roughly the same amount of performance.

> **How do I know what temperature my machine dies at?**
> The trace tells you. After a power cut, look at the last lines before the gap — they
> were fsynced, so they survived. If the last reading is well below Tjmax, you have the
> same problem this tool was built for. Set `CRIT_C` a degree or two below that
> temperature and `WARN_C` several degrees lower still.

### Two ways to cap

**A — constant cap.** `NORMAL_WATTS=11` applies always. The die never approaches
trouble; you never run at full speed. Safest and most predictable.

**B — temperature ladder.** Run unlimited while cool, step down as it heats:

```bash
TIERS="80:11 85:7"
#      ^      ^
#      |      at 85°C: cap to 7W and pull max_perf_pct down
#      at 80°C: cap to 11W
```

Rungs are `temp:watts`, ascending, all below Tjmax. A rung engages after
`TIER_SAMPLES` consecutive samples at or above it, and releases once the
temperature falls `TIER_HYSTERESIS` degrees below it. **Only the top rung** also
limits `max_perf_pct` — lower rungs cap power only, which keeps the machine
responsive. Set `NORMAL_WATTS` as well and it becomes the baseline the ladder
returns to instead of stock.

**Which should you use?** If your machine cuts power *below* Tjmax, the honest
answer is a **constant cap with real margin**. A ladder spends that margin to buy
performance, and reaction is not instant — polling is every `POLL_SEC` and the die
keeps climbing for a few seconds after a cap lands. **Overshooting a rung by 2–4 °C
is normal**, so leave room between your top rung and the temperature your machine
actually misbehaves at.

One more thing worth knowing: if a rung's budget settles *above* that rung's own
temperature, a sustained load never falls back out of it and the ladder degenerates
into a constant cap. Not a fault — but it means the benefit is real mainly for short,
bursty work.

Both variants for the case-study machine ship as
[`examples/asus-s550ca.conf`](examples/asus-s550ca.conf) (constant) and
[`examples/asus-s550ca-tiered.conf`](examples/asus-s550ca-tiered.conf) (ladder),
each annotated with the measurements behind every number.

---

## Hardware support

| Platform | Power capping | Clamping | Monitoring + trace |
|---|---|---|---|
| Intel + `intel_pstate` | ✅ RAPL | ✅ | ✅ |
| Intel + `acpi-cpufreq` | ✅ RAPL | ⚠️ no `max_perf_pct` | ✅ |
| AMD | ❌ *(see below)* | ❌ | ✅ |
| ARM / other | ❌ | ❌ | ✅ if a sensor exists |

**AMD:** recent kernels expose RAPL *energy counters*, but AMD does not support RAPL
power *limiting* through `powercap` — there is nothing to write. thermal-guard detects
this and runs monitor-only. For capping on AMD, look at
[`ryzenadj`](https://github.com/FlyGoat/RyzenAdj), or limit `scaling_max_freq`.

**BIOS-locked RAPL:** some firmware rejects power-limit writes. thermal-guard notices
and tells you, instead of silently doing nothing.

Nothing is hardcoded per vendor or model. Tjmax, the stock power limit, the RAPL
package domain and the temperature sensor are all discovered at runtime — **by name,
never by index**, because `hwmon*` and `thermal_zone*` numbering is not stable across
reboots. Diagnostics always distinguish *"your hardware cannot do this"* from *"run it
as root"*.

---

## Configuration

Everything lives in `/etc/thermal-guard.conf`. Every option is documented inline in
[`thermal-guard.conf.example`](thermal-guard.conf.example).

| Option | Default | What it does |
|---|---|---|
| `NORMAL_WATTS` | *unset* | Constant package power budget, applied always. **Unset means stock.** Decimals allowed. |
| `TIERS` | *unset* | Temperature ladder, e.g. `"80:11 85:7"` — ascending `temp:watts` rungs |
| `TIER_SAMPLES` | `3` | Consecutive samples at a rung before it engages |
| `TIER_HYSTERESIS` | `7` | Degrees below a rung before it releases |
| `CLAMP_WATTS` | 70% of `NORMAL_WATTS` | Emergency budget once `WARN_C` is reached |
| `CLAMP_PERF_PCT` | `40` | `intel_pstate` performance ceiling while clamped |
| `WARN_C` | `Tjmax - 10` | Clamp here |
| `CRIT_C` | `Tjmax - 5` | Fire `CRIT_ACTION` here |
| `RECOVER_C` | `WARN_C - 7` | Release the clamp below here |
| `CRIT_SAMPLES` | `3` | Consecutive samples at `CRIT_C` before acting |
| `CRIT_ACTION` | `throttle-only` | `log-only` \| `throttle-only` \| `poweroff` |
| `DISABLE_TURBO` | `no` | On a chassis that cannot dissipate its rated power, turbo drives the runaway |
| `RESTORE_ON_EXIT` | `yes` | Put stock values back on a clean stop |
| `POLL_SEC` | `2` | Sampling interval |

Bad values are rejected at startup with a clear message rather than causing odd
behaviour later.

> ⚠️ **`CRIT_ACTION=poweroff` will shut down your machine.** Use it only if yours cuts
> power abruptly below Tjmax and you would rather lose the session than the unsaved
> work. `throttle-only` is the default because a daemon that powers off your computer
> by surprise is a bad neighbour.

---

## Reading the trace

`/var/log/thermal-trace.log` — one line per sample, fsynced every 5 samples so at most
~10 s can be lost to a power cut. Event lines start with `#`, so samples are trivially
parseable:

```
# 2026-08-07T16:56:55+03:00 started v1.0.0: tjmax=105C warn=85C crit=88C budget=11
2026-08-07T16:56:57+03:00,76,0
2026-08-07T16:56:59+03:00,78,0
# 2026-08-07T16:57:01+03:00 CLAMP ON  temp=85C -> 7W / max_perf_pct=40
2026-08-07T16:57:01+03:00,85,1
                          ^  ^
                          |  clamped: 0 or 1
                          package temperature, °C
```

Peak temperature since boot, ignoring event lines:

```bash
grep -v '^#' /var/log/thermal-trace.log | awk -F',' '{if($2>m)m=$2} END{print m"°C"}'
```

Live decisions:

```bash
journalctl -fu thermal-guard
```

---

## Uninstall

```bash
sudo ./uninstall.sh            # restores stock power limit and turbo
sudo ./uninstall.sh --purge    # also removes config, saved state and trace
```

thermal-guard saves your machine's real stock values the first time it runs
(`/var/lib/thermal-guard/`) and restores *those* — not a hardcoded guess at your TDP.

> **Why this matters:** the power limit and turbo flag live in **hardware registers**.
> They persist after the process exits and only clear on a full power cycle. A naive
> uninstall that just stops the service would leave your CPU capped with nothing
> running to explain why.
>
> thermal-guard handles this in two places: it restores stock on `SIGTERM` (so
> `systemctl stop` is safe), and `uninstall.sh` restores again as a backstop for the
> case where it was `SIGKILL`ed or lost power mid-clamp.

---

## How this compares

Being straight about the overlap:

| Tool | What it is | Why you might want this instead |
|---|---|---|
| [thermald](https://github.com/intel/thermal_daemon) | Intel's own thermal daemon, more sophisticated modelling | With no config it drives off the ACPI trip points — which on affected boards sit *above* Tjmax and therefore never fire. It also cannot help when the machine dies below Tjmax. |
| [throttled](https://github.com/erpalma/throttled) | RAPL capping + undervolting for Lenovo throttling bugs | Overlapping mechanism, different goal, no crash-surviving telemetry |
| TLP, auto-cpufreq | Power *management* for battery life | Not aimed at thermal emergencies |

**thermal-guard's niche is narrow and specific:** a machine that removes power *below*
Tjmax, where you need both a hard envelope and evidence of what happened. If your
laptop throttles normally and never cuts out, you probably want thermald.

Note that thermald and thermal-guard both write `intel_pstate/max_perf_pct`. The
shipped unit declares `Conflicts=thermald.service` so they cannot fight. To keep
thermald instead, delete that line and run with `CRIT_ACTION=log-only`.

---

## Troubleshooting

**`can cap power: NO — not writable — needs root`**
Run it with sudo, or via the systemd service.

**`can cap power: NO — no Intel RAPL package domain`**
AMD or a kernel without `intel_rapl`. Monitoring still works; capping does not.

**`BIOS rejected the write (registers locked)`**
Your firmware has locked the RAPL registers. Power capping is unavailable; the
`max_perf_pct` clamp still works if `intel_pstate` is present.

**`Tjmax: 100C (NOT DETECTED — assumed...)`**
No `coretemp` sensor exposing `temp1_crit`. The derived thresholds are guesses — set
`WARN_C` and `CRIT_C` yourself.

**The clamp keeps engaging**
Your budget is too high for current conditions. Lower `NORMAL_WATTS` by 1 W. Ambient
temperature matters a lot — the case-study machine needed about 2 W less on a 34 °C
balcony than indoors.

---

## Requirements

bash 4+, coreutils, `logger` (util-linux, optional — falls back to the trace file).
systemd optional. Root to cap power; `--detect` works unprivileged.

## Contributing

Reports from hardware I do not have are the most useful contribution — especially AMD,
`acpi-cpufreq` systems, and machines with an unusual Tjmax. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
