# thermal-guard

**Your laptop shuts off under load, with nothing in the logs. This finds out why, and stops it.**

[![CI](https://github.com/anatoli-iliev/thermal-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/anatoli-iliev/thermal-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25)
![Platform](https://img.shields.io/badge/platform-Linux-blue)

thermal-guard keeps a CPU inside a thermal envelope it can actually sustain, and
records what happened if the machine dies anyway.

---

## In one minute

**The problem.** Some laptops switch off instantly under heavy load. No warning, no
error, nothing in the logs. That is because the power is cut *underneath* the
operating system — Linux never gets the chance to write anything down.

**Why it happens.** The CPU is allowed to draw more power than the laptop's cooling
can carry away. It overheats, and the board cuts power to protect itself. On many
machines that happens well below the temperature the CPU itself considers dangerous,
so the safety net built into Linux never fires. You are left with a dead machine and
no evidence.

**What this does about it.**

1. **Puts a ceiling on how much power the CPU may draw**, so the chip never gets hot
   enough for that to happen.
2. **Steps in harder** if the temperature climbs anyway.
3. **Writes a temperature reading every two seconds to a file that survives a power
   cut** — so if the machine does die, you finally have evidence instead of a guess.

**What makes it unusual.** How much power is safe depends on how warm it is *around*
the machine. The same laptop that is perfectly happy at 11 W in a cool room will die
at 11 W on a hot balcony. thermal-guard can look up the outdoor temperature for your
location once an hour and move the ceiling to match: **more power when it is cold,
less when it is hot.** It also decides *how* to cap — some conditions are better
served by a fixed limit, others by running at full speed until the chip warms up and
only then stepping down. It picks, and it tells you why in a sentence you can argue
with.

**It changes nothing until you ask it to.** A fresh install only watches and records.
Nothing is capped, nothing is shut down, and nothing is sent over the network. You
switch things on after you have looked at your own data.

### What is in the box

| | |
|---|---|
| **`thermal-guard`** | the daemon: caps power, clamps if needed, records everything |
| **[`contrib/thermal-summary.sh`](contrib/thermal-summary.sh)** | one screen: what is in force, how hot it is now and has been, what changed |
| **[`contrib/thermal-clamps.sh`](contrib/thermal-clamps.sh)** | the detailed view: every time it had to throttle, for how long, at what power, and how warm it was outside |

### Getting started

```bash
git clone https://github.com/anatoli-iliev/thermal-guard.git
cd thermal-guard && sudo ./install.sh     # monitors only — caps nothing

thermal-guard --detect                    # what it found on your machine
./contrib/thermal-summary.sh              # what it has seen so far
```

Then leave it running for a day and read [Choosing a power budget](#choosing-a-power-budget).
If you want it to track the weather for you, see [Adapting to the weather](#adapting-to-the-weather).
To watch what it is doing, see [Monitoring it day to day](#monitoring-it-day-to-day).

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

### The numbers were not the answer — the equation was

Two more measurements turned that hand-tuned budget into something transferable.
Thermal resistance came out at **5.24 °C/W**, and the machine was found to die at
**89 °C**, so a safe die target is 83 °C. Those two facts alone reproduce the whole
afternoon of trial and error:

```
indoors, 25 °C ambient:   (83 − 25) / 5.24 = 11.07 W    → the hand-tuned 11 W
34 °C balcony:            (83 − 34) / 5.24 =  9.35 W    → the 9 W that worked there
```

The tuning was never really about 11 W. It was about `die = ambient + Rθ × watts`,
with the ambient silently changing between the two experiments. Give the daemon the
ambient and it does that arithmetic hourly — see
[Adapting to the weather](#adapting-to-the-weather).

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
thermal-guard 1.2.0 — detected configuration

hardware
  temperature source : /sys/class/thermal/thermal_zone7/temp
  Tjmax              : 105C
  RAPL package       : /sys/class/powercap/intel-rapl:0
  current power limit: 17.0W
  can cap power      : yes
  intel_pstate       : available
  current temp       : 71C
...
  Nothing will be capped: no baseline budget and no tier ladder. This is the
  default.

adaptive
  status             : off (ADAPTIVE=no) — no network, no derived values, v1.1 behaviour
```

At this point it is only watching. Nothing about your machine has changed, and
nothing has left it.

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

### Three ways to cap

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

**C — weather-adaptive.** `ADAPTIVE=yes`, and you set neither of the above. The
daemon fetches the outdoor temperature for your location once an hour, estimates the
ambient at the machine, and derives A or B from it — including the watts. Cold day,
more watts. Heatwave, fewer watts and no ladder. See
[Adapting to the weather](#adapting-to-the-weather) below; it is off by default and
uses no network until you turn it on.

It does not remove the judgement above, it just makes it hourly with the day's actual
heat as an input. **If you already know your numbers, keep them** — an explicit
`NORMAL_WATTS`, `TIERS` or `CLAMP_WATTS` pins the plan and the engine drops to
advisory for good.

All three variants for the case-study machine ship as
[`examples/asus-s550ca.conf`](examples/asus-s550ca.conf) (constant),
[`examples/asus-s550ca-tiered.conf`](examples/asus-s550ca-tiered.conf) (ladder) and
[`examples/asus-s550ca-adaptive.conf`](examples/asus-s550ca-adaptive.conf) (weather),
each annotated with the measurements behind every number.

---

## Adapting to the weather

A budget tuned in February is wrong in August. This is the section about why, and
what the daemon does about it.

### The one equation

A die settles where the heat it makes equals the heat the chassis can move away:

```
die temperature  =  ambient temperature  +  Rθ × package watts
```

`Rθ` (thermal resistance) is your cooling, in degrees of die rise per watt. It is a
property of the machine — 5.24 °C/W on the case-study laptop, about 3.53 for a
healthy design of that class. The watts are the only term this daemon controls. And
the ambient is neither: it is just the room, and it moves 15 °C between a winter
morning and an August afternoon.

Rearranged, that is the whole feature:

```
watts  =  (die target − ambient) / Rθ
```

**This is why cold weather buys watts.** Every degree the room drops is a degree of
die budget you did not have, and at `Rθ = 5.24` that is 0.19 W per degree. It is not
generosity, it is the same equation read left-to-right.

The die target is `CRIT_C − 5`, so the whole thing hangs off the one threshold you
measured from your own trace. **A `CRIT_C` that is a guess produces a budget that is
a guess** — the daemon says so at startup and in `--detect`, and that warning is the
most important line it prints.

### Quick start

Four keys, in `/etc/thermal-guard.conf`:

```bash
ADAPTIVE=yes
PLACEMENT=indoor       # or outdoor — a balcony, a van, a shed
LOCATION=auto          # or LATITUDE=42.7 / LONGITUDE=23.3
AMBIENT_OFFSET_C=0     # your thermometer minus what --detect says
```

Then look before you leap. Neither of these writes a hardware register or opens a
socket:

```bash
thermal-guard --detect          # what it would do right now, and why
thermal-guard --simulate 34     # what it would do if it were 34 °C outside
thermal-guard --simulate unknown  # what it does when the weather is unreachable
```

### Indoors uses the weather too

An indoor machine is the common case, and an outdoor-only feature would do nothing
for it. So indoors the fetched temperature is turned into a room estimate first:

```
room = INDOOR_BASE_C + INDOOR_COUPLING × max(0, outdoor − INDOOR_BASE_C)
```

Default `22 °C` and `0.35`: a heated or cooled building sits near 22 °C, and only
about a third of any outdoor heat *above* that gets in. **The `max(0, …)` is what
makes winter safe** — a −10 °C reading cannot push the assumed room below the heating
setpoint, so January does not authorise the whole stock budget. (Without that floor,
−10 °C outdoors would ask for 17.7 W on the case-study machine.)

Being straight about it: **22 and 0.35 are calibrated against one building in one
season.** The single anchor is 32 °C outdoors measuring 25.5 °C indoors. They will be
wrong somewhere. The escape hatches, in increasing order of bluntness, are
`AMBIENT_OFFSET_C` (a thermometer and a subtraction), then `INDOOR_BASE_C` /
`INDOOR_COUPLING` for a building that behaves differently in kind, then `AMBIENT_C`
to bypass the model and the network entirely.

`PLACEMENT=outdoor` skips all of that and uses the reading as-is. Getting placement
wrong indoors is safe — you get a smaller budget than you could have had. Getting it
wrong outdoors is not.

### Why a ladder is a bad bet when it is hot

A ladder's only benefit is the time spent *below* the first rung, running
unrestricted. That time exists only while the die at light load sits well below the
rung — and the light-load floor rises with the ambient while the rung does not. So
the gap collapses in the heat, and what you have left is a constant cap that
oscillates.

```
                 first rung 80 °C ────────────────────────────
25 °C ambient:   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 14.9 °C of burst window       → ladder is worth it
                 light-load floor 65.1 °C

                 first rung 80 °C ────────────────────────────
34 °C ambient:   ▓▓▓▓▓ 5.9 °C                                  → flat cap instead
                 light-load floor 74.1 °C
```

The daemon measures that gap (`LADDER_MIN_WINDOW_C`, default 8 °C, with 2 °C of
hysteresis so the mode cannot flip hourly) and picks the shape accordingly. On the
case-study machine the crossover lands at about **32 °C ambient**.

This is not theory. On a 34 °C balcony the hand-tuned `80:11 85:7` ladder clamped to
7 W over and over, and the result was **slower than simply running a steady 9 W**.
The engine now refuses to build that ladder.

It also refuses to build a rung it could never climb back down from: if the top
rung's own settling temperature would sit above its release point, the ladder is
rejected and a flat cap is used. That was the other half of the balcony failure — a
7 W clamp that stayed engaged for 11 minutes straight.

### What it decides for the case-study machine

`RTHETA_C_PER_W=5.24`, `CRIT_C=88` (die target 83 °C), `PLACEMENT=indoor`, stock 17 W.
Every row below is `thermal-guard --simulate` output, not arithmetic done by hand:

| Outdoor | Room estimate | Budget | Shape |
|---|---|---|---|
| ≤ 22 °C | 22.0 °C | **11.5 W** | ladder `80:11.5 85:7` |
| 25 °C | 23.1 °C | 11 W | ladder `80:11 85:7` |
| 30 °C | 24.8 °C | 11 W | ladder `80:11 85:7` |
| 34 °C | 26.2 °C | 10.5 W | ladder `80:10.5 85:6.5` |
| 40 °C | 28.3 °C | 10 W | ladder `80:10 85:6.5` |

Two things to notice. **Winter gives 11.5 W — half a watt above the owner's
hand-tuned 11 W**, and it is self-consistent: 11.5 W at a 22 °C room predicts 82.3 °C,
still under the 83 °C target. And an indoor machine essentially never leaves ladder
mode; it would need a room above 32 °C, i.e. an outdoor reading above 50 °C. That is
correct, because the failure that motivated this feature was measured **outdoors**.

Fed the two temperatures at which the shipped examples were measured, it reproduces
them exactly:

```bash
$ thermal-guard --simulate ambient=25      # indoors, where 11 W settles at ~83 °C
  decision                 LADDER
  would apply              TIERS="80:11 85:7"   baseline stock, perf 40 at the top rung

$ thermal-guard --simulate ambient=34      # the balcony
  decision                 CONSTANT CAP 9W
  would apply              NORMAL_WATTS=9   CLAMP_WATTS=6.30 at 85C   CLAMP_PERF_PCT=40
```

The first is byte-identical to
[`examples/asus-s550ca-tiered.conf`](examples/asus-s550ca-tiered.conf), chosen
automatically.

### Nudging the engine without pinning it

Sooner or later the engine hands you a number you would like to be a little larger.
The obvious move — writing `TIERS` or `CLAMP_WATTS` into the config — is a much
bigger change than it looks: **any explicit plan pins the whole thing**
(`mode=static`, `budget_src=config`) and the weather stops being consulted at all.
You would keep your watt on a cold night and keep it on a 40 °C afternoon too.

Two keys move one number each and leave the rest adaptive:

| ambient | plain | `ADAPTIVE_CLAMP_OFFSET_W=1` | `ADAPTIVE_BUDGET_OFFSET_W=1` |
|---|---|---|---|
| 15 °C | `80:12.5 85:8` | `80:12.5 85:9` | `80:13 85:8` |
| 20 °C | `80:12 85:7.5` | `80:12 85:8.5` | `80:12 85:7.5` |
| 25 °C | `80:11 85:7` | `80:11 85:8` | `80:11 85:7` |
| 30 °C | `80:10 85:6.5` | `80:10 85:7.5` | `80:10 85:6.5` |
| 34 °C | constant 9 W, clamp 6.30 W | constant 9 W, clamp **7.30 W** | constant 9 W, clamp 6.30 W |

**Neither is a floor.** Both are requests, trimmed by the physics that would
otherwise be violated — and the two are bounded by *different* limits, which is why
they behave so differently in that table.

`ADAPTIVE_CLAMP_OFFSET_W` raises the emergency rung, bounded by the **release
budget**: the power above which the rung settles the die above its own release
temperature and can never let go. That was a measured failure — a clamp stuck for
11 minutes in the field — so the offset is added *inside* that bound. There is
usually room there, which is why the full watt lands at every row above.

`ADAPTIVE_BUDGET_OFFSET_W` raises the working rung, and its bound is much tighter,
because the working rung **settles the die by construction**: at budget B and
ambient A the die comes to rest at `A + Rtheta × B`. Push B until that resting point
reaches the emergency rung and the rung engages under ordinary load — the engine
rejects such a ladder outright and falls back to a constant cap, which would cap the
machine at *every* temperature and cost you the uncapped band under the first rung.
Asking for more would end in less, so the request is trimmed instead.

That bound is worth stating in watts, because it is small. All this key can ever hand
you is the slack between the die target and the emergency rung:

```
(85 °C rung − 83 °C die target) ÷ 5.24 C/W = 0.38 W   on a 0.5 W quantisation step
```

So on this machine it yields **+0.5 W or nothing**, never the full watt, whatever you
set it to — `+0.5 W` at 15/18/21/23/28 °C, nothing at 25 or 30 °C where the step
boundary falls the wrong way. If you want more than that, no offset will do it: the
lever is `DIE_TARGET_C`/`CRIT_C` (deciding to run the die hotter) or a genuinely lower
`RTHETA_C_PER_W` (better cooling, measured rather than wished for).

The watts it does hand you come out of `DIE_TARGET_MARGIN_C`, which covers
package-versus-hottest-core error, die ripple and ambient error. A die that settled at
80.9 °C now settles at 83.6 °C — still under the rung, with less room to wobble before
the clamp fires, so expect more clamp episodes on a marginal day.
[`contrib/thermal-clamps.sh`](contrib/thermal-clamps.sh) is how you check that.

`--detect` and `--simulate` print the governing bound beside each request, so you can
see how much of it actually landed:

```
  clamp offset             +1W asked for   (release budget here is 9.48W — the offset is trimmed to fit under it)
  budget offset            +1W asked for   (the die must settle under the 85C rung, so at most 11.77W here)
```

Neither key changes when a clamp *releases*: that is set by the rung temperature and
`TIER_HYSTERESIS`, not by watts. An 8.5 W clamp at the 85 °C rung still releases below
78 °C, exactly as a 7 W one did.

### Putting a ceiling on the clamp

The offsets push a number up; `ADAPTIVE_CLAMP_MAX_W` stops one climbing. The clamp is
a fraction of the working budget, and that budget grows as it gets colder, so the
clamp grows with it — on this machine `85:7.5` at 20 °C ambient becomes `85:12` at
−5 °C. That is honest physics (a cold machine really can shed 12 W at 85 °C), but it
may be more than you want the emergency rung ever handing out, and no other key says
"never above this" — `BUDGET_MAX_W` ceilings the working budget, not the clamp.

**It defaults to 9 W**, which is sized for the ~17 W-class laptop this project was
measured on. On a larger part that default sits below `BUDGET_MIN_W` (25 % of stock,
so 31 W on a 125 W CPU); the floor outranks it and `--detect` names the conflict, but
you should set a proportionate value or turn it off:

```bash
ADAPTIVE_CLAMP_MAX_W=9      # the default
ADAPTIVE_CLAMP_MAX_W=       # empty: no ceiling, as before this key existed
```

| ambient | without | with `ADAPTIVE_CLAMP_MAX_W=9` |
|---|---|---|
| −5 °C | `80:17 85:12` | `80:17 85:9` |
| 0 °C | `80:16 85:11` | `80:16 85:9` |
| 10 °C | `80:14 85:10` | `80:14 85:9` |
| 18 °C | `80:12.5 85:9` | `80:12.5 85:9` — already under |
| 30 °C | `80:10 85:7.5` | `80:10 85:7.5` — untouched |

It holds in **both** plan shapes — the ladder top rung and the constant-cap clamp are
derived by different routes, and one key covers both — and it can only ever *lower* a
clamp. A ceiling above the derived number does nothing at all.

It loses to `BUDGET_MIN_W`. A ceiling under the usability floor is a contradiction, so
the floor wins and `--detect` names the conflict rather than leaving you to wonder why
a 3 W ceiling produced a 4.25 W clamp:

```
  clamp ceiling      : 3W — the engine clamp never exceeds this, in either plan shape
  note               : warning: ADAPTIVE_CLAMP_MAX_W (3W) is below BUDGET_MIN_W (4.25W,
                       derived) — the usability floor wins and the clamp will not go
                       under 4.25W. Lower BUDGET_MIN_W too if you meant it
```

Like `BUDGET_MAX_W`, it bounds what the **engine** derives. An explicit `TIERS` or
`CLAMP_WATTS` is your own number and still wins outright.

### When it cannot reach the weather service

**It fails safe, never optimistic.** Every one of these lands in the same place —
`AMBIENT_FALLBACK_C` (default 35 °C, deliberately hot) and a constant cap:

| What went wrong | What the daemon does |
|---|---|
| No network, DNS dead, HTTP error, timeout | Keeps the last reading until it ages out, then falls back |
| Cached reading ageing towards `WEATHER_MAX_AGE_SEC` | Trusted less as it ages: at each quarter of the window the assumed ambient moves another quarter of the way to `AMBIENT_FALLBACK_C`, so the budget steps *down* while the evidence gets older |
| Cached reading older than `WEATHER_MAX_AGE_SEC` (3 h) | Falls back completely |
| Clock stepped backwards, so the reading has a *negative* age | Treated as stale, not fresh. Falls back |
| Reply is not a plausible number (`999`, `NaN`, `1e9`, HTML, empty) | Rejected, previous reading kept, logged once |
| Resumed from suspend after hours asleep | The reading is stale on the first tick back, so it drops to the fallback budget *first*, then fetches |
| Neither `curl` nor `wget` installed | Logged once as a note at startup. The daemon starts normally on the fallback |

On the case-study machine that fallback is **9 W** — the budget the measurements say
survives the hottest condition ever tested on it. The budget only ever goes *up* on
evidence. It never goes up on a guess, and a stale reading is a guess.

The 2-second guard loop **never waits on any of this.** The fetch runs in a detached
child with its own hard timeout; the loop only ever reads a cache file. `CRIT_C`, the
emergency rung and the trace all run off the local sensor every 2 seconds and do not
care whether the network exists.

The systemd unit deliberately does **not** carry `After=network-online.target`, for
the same reason. Ordering a thermal guard behind DHCP would mean a boot where the
Wi-Fi is slow is a boot where the machine is unprotected — trading a guarantee for a
convenience. The daemon starts capped, on the conservative budget, and relaxes when
and if the weather arrives. The first fetch is scheduled 15–315 seconds after start,
jittered so a crash-looping service cannot hammer a free public API.

### Privacy: what leaves this machine

**With `ADAPTIVE=yes` and `AMBIENT_C` empty, and only then, thermal-guard makes
outbound network requests.** That rule is exact, it is the only rule, and `--detect`
prints the current answer verbatim on a line that says either
`network : YES — outbound HTTPS to api.open-meteo.com every 3600s` or
`network : none`.

| | |
|---|---|
| **What leaves** | A latitude and longitude, **rounded to one decimal place (~11 km)**, and a User-Agent naming the tool and version. Nothing else — no hostname, no serial, no temperatures, no configuration, no identifier of any kind |
| **To whom** | `api.open-meteo.com` for the weather. Plus `get.geojs.io` **once**, and only if `LOCATION=auto`, to turn your IP into coordinates — retried on the next hourly attempt until it succeeds, then cached on disk and never asked again. Both free, both keyless, neither asked to remember you |
| **How often** | One HTTPS GET per hour (`WEATHER_INTERVAL_SEC`, minimum 600). Nothing on shutdown, nothing on any other schedule |
| **Stored where** | Coordinates in `/var/lib/thermal-guard/location`, mode 0600. Temperature in `/var/lib/thermal-guard/weather`, mode 0644 |

**Turning it off**, in increasing order of bluntness:

- `ADAPTIVE=no` — the default. No requests, no state files, no adaptive code runs at all.
- `AMBIENT_C=25` **with** `ADAPTIVE=yes` — the whole engine, the physics and the
  ladder/constant decision, with the network completely disabled. See
  [`examples/adaptive-offline.conf`](examples/adaptive-offline.conf).
- `LATITUDE`/`LONGITUDE` instead of `LOCATION=auto` — the weather is still fetched,
  but your IP is never sent anywhere to be resolved. **Do this if you use a VPN**,
  which would otherwise put your laptop in the wrong city and the wrong weather.

Coordinates are rounded even when you type them at full precision, because
Open-Meteo snaps to a ~7 km grid anyway — the extra digits would buy no accuracy and
leak a street address. `--detect` says so, so the difference from what you typed is
never a mystery.

Removing what has been cached: `sudo rm -f /var/lib/thermal-guard/{weather,location}`.

### Treating the network as hostile

The daemon runs as root and now reads bytes from the internet. Those bytes are
**never** `eval`ed, `source`d, word-split, or passed to a command. `awk` reads the
body on stdin and prints at most one number; that number must then match a bash regex
and fall in −90…60 °C before it can influence anything. Both cache files are read line
by line, never sourced. Only `https://` URLs are accepted, with a character allowlist
that excludes whitespace, quotes, backticks, pipes and angle brackets.

A **fully attacker-controlled weather feed** can at worst report an implausibly cold
ambient, and four independent layers bound what that buys:

1. TLS with certificate validation and `--proto '=https'`, so a plaintext MITM cannot
   connect at all.
2. Indoors, the `max(0, …)` floor means no reported temperature, however cold, pushes
   the assumed room below `INDOOR_BASE_C`.
3. `BUDGET_MAX_W` defaults to the CPU's own rated limit as published by the firmware,
   so the worst outcome on the outdoor path is the power the part is rated for.
4. `CRIT_C` and the emergency rung run every 2 seconds off the local sensor and are
   completely independent of the network.

A spoofed *hot* reading costs performance only.

### The general formula, for machines that are not this laptop

With `RTHETA_C_PER_W` unset the daemon assumes
`Rθ = (Tjmax − 40) / stock_watts × 1.4` — the design point *"sustain the stock power
limit with the die at Tjmax − 15 in a 25 °C room"*, derated by 40% because a machine
that is dying under load does not have as-designed cooling. On the one machine where
both are known it lands at 5.35 against a measured 5.24, and reproduces **both** field
anchors within one 0.5 W step with no measured input at all.

Substituted back, the budget at a 25 °C ambient is a fixed fraction of stock,
**independent of TDP**:

```
budget / stock  =  (CRIT_C − 30) / (1.4 × (Tjmax − 40))
```

| Tjmax | Stock | `CRIT_C` | Rθ assumed | Budget @ 25 °C | % of stock |
|---|---|---|---|---|---|
| 105 °C | 17 W | 100 (default) | 5.35 | 13 W | 77% |
| 100 °C | 15 W | 95 (default) | 5.60 | 11.5 W | 77% |
| 100 °C | 28 W | 95 (default) | 3.00 | 21.5 W | 77% |
| 105 °C | 125 W | 100 (default) | 0.73 | 96 W | 77% |
| 105 °C | 17 W | **88 (measured)** | 5.35 | 10.5 W | **64%** |

The percentage is the formula's answer; the budget column is that answer rounded
down to the 0.5 W grid, which is why 13 W of 17 W reads as 76% if you divide it out.

So: **77% of stock on a machine that throttles normally, and about 64% once you tell
it the temperature your machine actually dies at.** That second number is this
README's hand-written *"start at roughly 60% of stock"* advice, arrived at from
physics instead of from trial and error. Set `CRIT_C`, and measure `Rθ` — the
`--detect` output tells you how.

### Known limitations, stated plainly

- **`Rθ` is treated as a constant and it is not.** On the case-study machine it reads
  8.70 at idle, 6.05 at one thread, and converges near 5.34 only once the fan
  saturates. The design uses the loaded figure because that is the regime a sustained
  budget is for. There is also unresolved evidence it *rises* under a long heat soak:
  the balcony trace implies `Rθ ≥ 6.29` at one point, 20% above the design basis. If
  that is real and sustained, 11 W indoors asymptotes to 94 °C. The mitigations are
  `DIE_TARGET_MARGIN_C`, the top rung and `CRIT_C` — and measuring your own.
- **An AC-versus-battery contradiction is unresolved.** The same machine measured 5.24
  on mains and 3.80 on battery. The tool uses whatever single number you give it; give
  it the worse (larger) one.
- **The indoor ladder is marginal, not comfortable.** 11 W settles at ~82.6 °C against
  an 85 °C top rung — 2.4 °C of margin, and overshoot past a rung is 2–4 °C. The 3 °C
  between the top rung and `CRIT_C` is what absorbs it. `LADDER_TOP_MARGIN_C` widens
  it directly — but it widens it *downwards*, towards the temperature the budget
  settles at, so keep it below `DIE_TARGET_MARGIN_C` (default 5). Cross that line and
  the emergency rung would sit under ordinary load; the daemon then lowers the die
  target to one degree under the rung — and the budget with it — and says so at
  startup and in `--detect`. Raising `DIE_TARGET_MARGIN_C` by the same amount is the
  deliberate way to buy margin: it costs watts instead of borrowing them.
- **`LADDER_IDLE_RISE_C` is the softest number in the design.** Left unset it is
  derived from the *detected* stock limit, and it decides the ladder-versus-constant
  crossover. Measure it: idle until the temperature stops falling, then
  `idle_die_temp − ambient`.
- **`--simulate` reports steady state only.** It does not model the 0.4–0.8 °C/s ramp
  or the overshoot past a rung, so it cannot tell you how hot it actually gets before
  the ladder catches it.
- **`BUDGET_MIN_W` is a usability floor, not a safety floor.** It is the one place the
  engine can hold a budget *above* what the physics asks for. The top rung, `WARN_C`
  and `CRIT_C` all still act below it, and `--detect` prints `clipped-floor` when it
  binds.

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

### Core

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

### Adaptive

Off by default. **With `ADAPTIVE=no` not one of these has any effect**, no adaptive
code runs, no state file is written and no socket is opened — v1.1 behaviour byte for
byte. The precedence rule is one sentence: *the engine only ever fills in a plan you
left empty.* If `NORMAL_WATTS`, `TIERS` or `CLAMP_WATTS` holds a value, the engine
computes, prints and warns, but changes nothing.

**The four bold rows are the ones a normal user sets.** The rest have reasoned
defaults; see [`thermal-guard.conf.example`](thermal-guard.conf.example) for what each
one costs you.

| Option | Default | What it does |
|---|---|---|
| **`ADAPTIVE`** | `no` | Master switch. `no` = nothing below runs at all |
| **`PLACEMENT`** | `indoor` | `indoor` derives a room temperature from the outdoor reading; `outdoor` uses it as-is |
| **`LOCATION`** | *unset* | `auto` (resolve from your IP once, then cached on disk for good) or `"lat,lon"`. **Place names are not accepted** |
| **`AMBIENT_OFFSET_C`** | `0` | Degrees added to the derived ambient. Your thermometer minus what `--detect` says. The first knob to reach for |
| `ADAPTIVE_MODE` | `auto` | Prefer a shape: `auto` \| `ladder` \| `constant`. Never overrides a pinned plan. `ladder` still yields to the two cases where no ladder exists: an untrusted ambient, and a budget with no room for a step below it — `--simulate` names which |
| `LATITUDE` / `LONGITUDE` | *unset* | Explicit coordinates. Always beat `LOCATION`, and your IP is never sent anywhere. Set both or neither |
| `AMBIENT_C` | *unset* | A fixed ambient at the machine. **Suppresses all network use** and never expires |
| `AMBIENT_FALLBACK_C` | `35` | Ambient assumed when the real one is unknown, stale or implausible. **This is the fail-safe, so it must be hot** |
| `RTHETA_C_PER_W` | *derived* | Degrees the die rises per watt — your cooling. **Measure it**; the whole budget scales with it |
| `DIE_TARGET_C` | `CRIT_C − DIE_TARGET_MARGIN_C` | Steady-state die temperature the budget aims for |
| `BUDGET_MIN_W` | `max(4, 25% of stock)` | Usability floor, **not** a safety floor — the top rung and `CRIT_C` still act below it |
| `BUDGET_MAX_W` | the CPU's rated limit, read from `constraint_0_max_power_uw` | Ceiling. A value you set is used **as written**, never clipped down — you get a warning naming both numbers instead |
| `INDOOR_BASE_C` | `22` | What a heated/cooled building sits at. The indoor estimate never goes below this |
| `INDOOR_COUPLING` | `0.35` | Fraction of the outdoor excess above `INDOOR_BASE_C` that reaches the room |
| `DIE_TARGET_MARGIN_C` | `5` | Gap below `CRIT_C`: 1 °C package-vs-core + 2 °C die ripple + 2 °C ambient error |
| `RTHETA_DERATE` | `1.4` | How much worse than its design point to assume cooling is, when `RTHETA_C_PER_W` is unset |
| `BUDGET_STEP_W` | `0.5` | Quantisation, always rounded **down**. Doubles as the change deadband |
| `LADDER_START_MARGIN_C` | `3` | First generated rung sits this far below the die target |
| `LADDER_TOP_MARGIN_C` | `3` | Top generated rung sits this far below `CRIT_C`. This is your overshoot margin |
| `LADDER_TOP_FACTOR` | `0.65` | Top-rung watts as a fraction of the budget, reduced further if the rung could not release |
| `ADAPTIVE_CLAMP_OFFSET_W` | `0` | Watts added to the engine's emergency clamp, keeping the plan adaptive. Trimmed to whatever the release bound allows, so it is a request rather than a floor |
| `ADAPTIVE_BUDGET_OFFSET_W` | `0` | Watts added to the working rung — the band between the first and emergency rungs. Ladder plans only, and trimmed to keep the die settling below the emergency rung, since a ladder that cannot hold becomes a constant cap |
| `ADAPTIVE_CLAMP_MAX_W` | `9` | Hard ceiling on the engine's emergency clamp, in both plan shapes and at every ambient. Only ever lowers a clamp; loses to `BUDGET_MIN_W`. Set empty for no ceiling. Sized for a ~17 W laptop — raise it on a larger part |
| `LADDER_MIN_WINDOW_C` | `8` | Minimum burst window before a ladder beats a flat cap. ±2 °C of hysteresis around it |
| `LADDER_IDLE_RISE_C` | `0.45 × Rθ × stock` | Die rise above ambient at light load. Decides the crossover — worth measuring |
| `WEATHER_URL` | Open-Meteo | `https://` only. Must return a `current` object with a numeric `temperature_2m` |
| `GEOIP_URL` | GeoJS | `https://` only. Used **only** by `LOCATION=auto`, once ever — the answer is cached on disk and re-read by every later fetch, across restarts |
| `WEATHER_INTERVAL_SEC` | `3600` | Fetch interval. Under 600 is refused |
| `WEATHER_TIMEOUT_SEC` | `10` | Hard timeout for one attempt. The guard loop never waits on it |
| `WEATHER_MAX_AGE_SEC` | `10800` | How long a reading is trusted **at all**; trust decays in quarters across it and the budget with it. Must be ≥ `WEATHER_INTERVAL_SEC`. Shorten it for `PLACEMENT=outdoor` |
| `ADAPTIVE_HEARTBEAT_SEC` | `900` | How often the active plan is restated in the trace, so a post-mortem can read it. `0` disables |

---

## Reading the trace

`/var/log/thermal-trace.log` — one line per sample, fsynced every 5 samples so at most
~10 s can be lost to a power cut. Event lines start with `#`, so samples are trivially
parseable:

```
# 2026-08-07T16:56:55+03:00 started v1.2.0: tjmax=105C warn=85C crit=88C budget=11
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

### What the adaptive engine writes

Three more event shapes, all `#` lines, so the CSV recipe above is untouched — there
is no fourth column and never will be.

```
# 2026-08-08T09:14:02+03:00 AMBIENT 24.6C indoor (outdoor 29.4C, age 312s, weather)
# 2026-08-08T09:14:02+03:00 PLAN ladder TIERS="80:11.5 85:7" (was ladder TIERS="80:11 85:7") — window 18.0C vs 8.0C at 22.0C ambient (window-ok)
# 2026-08-08T09:14:02+03:00 RESULT v=1 ambient_c=24.6 ambient_src=weather ambient_age_sec=312 rtheta=5.24 rtheta_src=config tjmax_c=105 crit_c=88 target_c=83 idle_floor_c=64.7 window_c=15.3 window_min_c=8.0 mode=ladder reason=window-ok budget_w=11 budget_src=engine tiers=80:11,85:7 clamp_w=7
```

- **`AMBIENT`** when the derived ambient moves 0.5 °C or its source changes. A
  weather → fallback transition is always logged.
- **`PLAN`** when the emitted plan differs from the active one, always naming the
  previous plan. **A mode change, or anything that takes performance away, is
  prefixed `warning:`** — those are the lines to read when the machine feels slow.
- **`RESULT`** after every `PLAN`, and every `ADAPTIVE_HEARTBEAT_SEC` (default 15 min)
  even when nothing changed. That heartbeat is the point: after a power cut, the last
  `RESULT` before the gap tells you exactly which budget and mode were in force. The
  temperature column alone cannot.

```bash
grep '^# .* RESULT '  /var/log/thermal-trace.log | tail -1   # what was active at the end
grep '^# .* PLAN '    /var/log/thermal-trace.log             # every plan change, ever
grep '^# .* AMBIENT ' /var/log/thermal-trace.log             # the ambient's whole history
```

`RESULT` is a stable contract: `v=1` first, fixed field order, every field always
present, `-` for not-applicable, no spaces inside any value. Adding a field or a
vocabulary word bumps `v`. `--detect` and `--simulate` print the same line, so you can
diff what the daemon is doing against what it says it would do.

---

## Monitoring it day to day

Every recipe below is a one-liner against `/var/log/thermal-trace.log` or the journal.
Nothing else to install. The `awk -F, 'NF==3'` guard skips event lines and also skips
traces written by 1.0.x, which used a different sample format.

```bash
T=/var/log/thermal-trace.log
```

### Watching it live

```bash
journalctl -fu thermal-guard        # decisions as they happen
tail -f "$T" | grep '^#'            # the same, but survives a power cut
watch -n2 thermal-guard --detect    # a dashboard: plan, ambient, budget, temps
```

### Is it throttling me right now?

The fraction of samples spent above the baseline. At 2 s polling, 1800 samples is the
last hour.

```bash
grep -v '^#' "$T" | awk -F, 'NF==3' | tail -1800 |
  awk -F, '{n++; c+=$3} END{if(n) printf "%d samples, %.1f%% clamped\n", n, 100*c/n}'
```

```
1800 samples, 20.4% clamped
```

A few percent is a ladder doing its job. Sustained high numbers mean the budget is
below what your workload wants — either the weather turned, or the machine wants a
constant cap rather than a ladder. Check which with the plan history below.

### How many clamps, and how long did each one last?

That percentage cannot tell ten one-second dips apart from one ten-second hold, and
those are very different machines. [`contrib/thermal-clamps.sh`](contrib/thermal-clamps.sh)
reports each **episode** — an unbroken stretch above the baseline tier — with how long
it actually ran:

```bash
./contrib/thermal-clamps.sh             # the last hour
./contrib/thermal-clamps.sh 6           # the last six hours
./contrib/thermal-clamps.sh 0.25        # the last fifteen minutes
./contrib/thermal-clamps.sh 1 -w 85 -c 88          # thresholds matching your own config
./contrib/thermal-clamps.sh 24 -f /mnt/rescued-trace.log
```

The window is the thing you change, so it is the first argument. `-f` points at a
different trace, `--help` lists the rest. The older `[file] [hours]` order still
parses — a positional that looks like a number is a duration, one that does not is a
path — so nothing written before this changed needs updating.

```
== thermal-guard: last 3h of /var/log/thermal-trace.log ==
window : since 2026-08-08 07:58:05
samples: 5389 over 3h00m (2.0s apart)

power
  applied now  : 17.0W   (live RAPL register on THIS machine)
  last applied : stock, no cap   (from the tier events in the trace)
  plan         : ladder, budget 10W
  ladder steps : baseline stock (uncapped)  ->  80C: 10W  ->  85C: 6.5W

outside
  reading      : 25.5C   (45m01s old when last used)
  used as      : 27.9C   (aged toward the conservative fallback, which is what shrinks the budget)
  in window    : min 22.6C  max 25.5C   (7 update(s), 2 fallback(s))

temperature
  latest       : 71C   (last sample, 4s ago)
  min 61C   mean 68.0C   max 85C
  at or above 80C : 10m40s (4.5%)
  at or above 85C : 8s (0.1%)

clamp episodes: 1   total 12m30s (5.2% of the window)
  #   started    lasted    peak   held at  outside
  1   09:27:18   12m30s    85C    11.5W    22.6C
  longest 12m30s, shortest 12m30s, mean 12m30s
```

Read together, those four blocks are one story: it was **22.6 °C outside** when the
clamp ran, so the budget then was **11.5 W**; it is **25.5 °C** now and that reading is
**45 minutes old**, so it has been aged to **27.9 °C** and the budget has come down to
**10 W**. Without the `outside` block the budget looks like it moved for no reason.

`reading` is the raw figure the weather service returned; `used as` is what the engine
actually computed with after ageing it toward the conservative fallback, and the two
are shown separately precisely because they disagree — a plan sized for 27.9 °C on a
25.5 °C day reads as a bug until you can see the ageing. On an indoor machine `reading`
is the outdoor temperature and `used as` is the room estimate after the coupling model.
The `outside` column on each episode is the reading at the time **that episode ran**,
not now. The whole block is omitted for a trace with no ambient events.

The **power** block is what makes the rest interpretable. `applied now` is the live
RAPL register and is labelled as *this* machine, never merged with the trace-derived
figures — reading a trace copied from another box is a supported use, and quietly
presenting your watts as its watts would mislead in exactly the situation where
someone is working out what killed something. `ladder steps` is the plan the engine
last committed, and `held at` is the budget that was in force **during that episode**,
which is not necessarily the one in force now: in the sample above the episode ran at
11.5 W and the current plan is 10.5 W, because the afternoon warmed up by 3 °C and the
engine stepped the budget down. A trace with no tier events shows `?` rather than
guessing.

`latest` is the newest sample in the trace, and it is always printed with its age
because the age is what makes it safe to read. A trace that stopped three hours ago
still has a newest sample, and on a machine you are looking at *because* it went down
that is the normal case — `71C (last sample, 3h04m ago)` is a very different statement
from `71C (last sample, 4s ago)`. The age is computed from the timestamps with
`date -d`; where that is unavailable the absolute clock time is printed instead
(`at 09:50:31`), because a wrong interval would be worse than none.

Durations come from the timestamps, not from a sample count times an assumed
`POLL_SEC` — the daemon can be restarted with a different interval, and a laptop can
suspend mid-episode. An episode still running when the window ends is marked
`(still clamped)`. The window is selected by timestamp, so a gap in the trace does not
silently widen it into yesterday.

Many short episodes mean the die is oscillating around a rung: the budget at that rung
settles near the rung's own temperature, so it trips, cools, releases and trips again.
That is the degenerate case where a constant cap beats a ladder — `ADAPTIVE_MODE=constant`,
or a wider `TIER_HYSTERESIS`. One long episode instead means the workload simply wants
more than the weather allows, which is the ladder working as designed.

### How hot did it actually get?

```bash
grep -v '^#' "$T" | awk -F, 'NF==3{t=$2+0; n++; s+=t; if(t>m)m=t;
  if(t>=80)h80++; if(t>=85)h85++}
  END{printf "n=%d  mean=%.1fC  peak=%.0fC  >=80C %.1f%%  >=85C %.1f%%\n",
      n, s/n, m, 100*h80/n, 100*h85/n}'
```

```
n=21501  mean=66.3C  peak=85C  >=80C 2.6%  >=85C 0.0%
```

Per hour, which is where a heat problem shows up as a pattern rather than a spike:

```bash
grep -v '^#' "$T" | awk -F, 'NF==3{split($1,a,"T"); split(a[2],b,":");
  k=a[1]" "b[1]":00"; t=$2+0; if(t>m[k])m[k]=t}
  END{for(k in m) printf "%s  peak %.0fC\n", k, m[k]}' | sort | tail -12
```

And the question that matters most on a machine that cuts power below Tjmax — did it
ever get close?

```bash
grep -v '^#' "$T" | awk -F, 'NF==3 && $2+0>=86' | tail -5
```

Empty output is the answer you want. Set the threshold to a couple of degrees under
whatever temperature *your* machine misbehaves at, not under Tjmax.

### What is in force right now?

```bash
grep '^# .* RESULT ' "$T" | tail -1
```

Or just the fields you care about:

```bash
grep '^# .* RESULT ' "$T" | tail -1 | tr ' ' '\n' |
  grep -E 'mode=|reason=|budget_w=|ambient_c=|ambient_src=|ambient_age_sec='
```

```
ambient_c=22.6 ambient_src=weather ambient_age_sec=1912
mode=ladder reason=window-ok budget_w=11.5
```

### What changed, and why?

```bash
grep '^# .* PLAN ' "$T"
```

Every plan change ever, each naming the plan it replaced and the reason. Anything that
takes performance away is prefixed `warning:`, so this is the first place to look when
the machine feels slow:

```bash
grep '^# .*warning: PLAN ' "$T" | tail
```

### Is the weather path healthy?

```bash
echo "updates: $(grep -c '^# .* AMBIENT ' "$T")  fallbacks: $(grep '^# .* AMBIENT ' "$T" | grep -c fallback)"
grep '^# .* AMBIENT ' "$T" | tail -3
```

```
updates: 5  fallbacks: 2
# 2026-08-08T09:50:31+03:00 AMBIENT 22.6C outdoor (outdoor 22.6C, age 1912s, weather)
```

`age` is how old the reading was when it was used. Fetches are hourly, so ages up to
~3600 s are normal and the influence of a reading decays as it ages. `ambient_src=fallback`
means no trusted reading at all and the conservative budget is in force — a couple at
startup is expected, a steady stream means the network or the endpoint is failing. Two
things to check then: `LOCATION`/coordinates resolved at all (the `location resolved`
event line), and whether `curl` or `wget` exists on the box.

### It died. What was in force?

The trace is fsynced every 5 samples, so at most ~10 s is lost to a power cut.

```bash
tail -40 "$T"                              # the seconds before it went
grep '^# .* RESULT ' "$T" | tail -1        # the policy that was active
```

The `RESULT` heartbeat exists for exactly this: temperature alone cannot tell you
whether the budget in force was 9 W or 17 W, and that is the difference between "the
cap was too generous" and "the cap held and something else killed it".

### A daily summary

All of the above in one screen — [`contrib/thermal-summary.sh`](contrib/thermal-summary.sh),
suitable for a cron job or a login shell:

```bash
./contrib/thermal-summary.sh            # the last 24 hours
./contrib/thermal-summary.sh 1          # the last hour
./contrib/thermal-summary.sh 24 -f /mnt/rescued-trace.log
```

```
== thermal-guard: last 24h of /var/log/thermal-trace.log ==
active : 2026-08-08T09:50:31+03:00 RESULT v=1 ambient_c=22.6 ambient_src=weather ... mode=ladder budget_w=11.5 tiers=80:11.5,85:7
temps  : now 71C (4s ago)  mean 66.3C  peak 85C  2.1% clamped  (21548 samples)
hot    : 5 samples at or above 85C  <- check what your machine actually misbehaves at
plans  : 1 change(s), 2 ambient fallback(s)
recent warnings:
# 2026-08-08T09:18:41+03:00 warning: PLAN ladder TIERS="80:11.5 85:7" (was constant 9W) — window 17.4C vs 8.0C at 22.6C ambient (window-ok)
```

It reads only the trace, so it also works on a machine where the daemon is not
running, on a trace copied from another box, and — the case it is really for — after
a power cut, when the trace is the only witness left.

That last case is why the leading temperature names itself. `now 71C (4s ago)` is a
live machine; once the newest sample is more than a minute old the word changes to
`last 71C (3h04m ago)`, so a reading taken from a trace that stopped hours ago cannot
be mistaken for the temperature right now.

---

## Uninstall

```bash
sudo ./uninstall.sh            # restores stock power limit and turbo
sudo ./uninstall.sh --purge    # also removes config, saved state and trace
```

`--purge` removes the config, the saved hardware state, the trace, **and both
adaptive cache files** — including `/var/lib/thermal-guard/location`, which holds
coordinates accurate to about 11 km of where the machine lives. It then removes the
state directory itself, and if anything unexpected is left in there it says so by
name instead of failing silently. To remove just the location without uninstalling:

```bash
sudo rm -f /var/lib/thermal-guard/location    # forgets where it thinks it is
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

One thing none of the tools above does: **none of them knows what the weather is.**
They all model the machine and none of them models the room the machine is in, which
is the term that moves 15 °C between seasons and is not under anyone's control. That
is the only capability here that is not available somewhere else — and it is optional,
off by default, and about fifty lines of arithmetic. Most of the rest of that feature
is making sure it can never make things worse than not having it.

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
balcony than indoors. This is what `ADAPTIVE=yes` exists to do for you.

**Why am I capped at 9 W?**
Run `thermal-guard --simulate ambient=$(your room temperature)` and read the `why`
line — it says in words which term of the equation ran out. If `--detect` shows
`budget_src=clipped-floor`, the physics asked for even less and `BUDGET_MIN_W` is
holding it up. If it shows `mode=constant reason=window-too-small`, see the next one.

**`--detect` says `reason=ambient-unknown`**
No trusted ambient, so the daemon is on `AMBIENT_FALLBACK_C` (35 °C) and a flat cap —
working exactly as designed. The `last fetch` line says why: `FAILED (http-403)`,
`FAILED (curl-6)` (DNS), `FAILED (unparseable)` (usually a captive portal),
`never` (no fetch has completed yet — the first one is jittered 15–315 s after start).
`AMBIENT_C=25` gives you the engine with no network at all.

**Neither `curl` nor `wget` is installed**
Not an error and never fatal. It is logged once as a `note:` at startup, and the
daemon runs on `AMBIENT_FALLBACK_C` forever — safe, and permanently conservative.
Install either one, or set `AMBIENT_C`.

**The ladder/constant mode keeps flipping**
It structurally cannot flip on weather noise: entry needs an 8 °C burst window, exit
needs it under 6 °C, and the budget moves on a 0.5 W grid. If you are genuinely
seeing it flap, your ambient estimate is swinging — check `AMBIENT_OFFSET_C` and the
`AMBIENT` lines in the trace, and consider that `PLACEMENT=outdoor` on a machine that
is actually indoors will track the real weather far more violently than the room does.

**The budget looks wrong and `--detect` shows a stock limit you do not recognise**
`--detect` prints it on its own line in the adaptive block, with where it came from:

```
  stock power limit  : 17W  (from hardware rating /sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw — compare this with your CPU's rated TDP)
  saved snapshot     : 11W  (restored on exit; NOT used for budgets)
```

Those two lines answer **different questions**, and conflating them was a real defect
in this tool:

| | what it is | what it drives |
|---|---|---|
| **stock power limit** | what the CPU is *rated* to sustain, read from the firmware's own `constraint_0_max_power_uw` | the `BUDGET_MAX_W` ceiling, the derived `LADDER_IDLE_RISE_C`, and the engine's uncapped baseline |
| **saved snapshot** | what was in the register *before this daemon first ran* | only what gets restored on a clean stop |

The snapshot is a copy of the live register taken on the first ever run. If that run
happened while an earlier experiment had already capped the package, the snapshot
records the **cap** as though the machine shipped with it, and it never self-corrects —
the file is written once and only once. Until 1.2.0 the snapshot was also the answer to
the first question, which meant one stale file quietly held three separate derivations
at the wrong value. On the case-study machine it pinned an 11 W cap onto a 17 W part:
the ceiling became 11 W so cold weather bought nothing, the idle-rise estimate came out
14 °C too cool so a ladder looked viable on days that wanted a flat cap, and tier 0
logged `stock` while applying 11 W, so the burst headroom the ladder exists to buy was
simply absent.

The rating is now read from the hardware, so a stale snapshot no longer touches any
budget. The second line only appears when the two disagree. It still matters, because
`RESTORE_ON_EXIT=yes` will put that old cap back when you stop the service — to correct
it, stop the service, delete `/var/lib/thermal-guard/stock-power-limit-uw`, reboot so
the register returns to its firmware value, and start again.

If your firmware publishes no rating, or publishes a wrong one, set `BUDGET_MAX_W` and
`LADDER_IDLE_RISE_C` explicitly — which is what
[`examples/asus-s550ca-adaptive.conf`](examples/asus-s550ca-adaptive.conf) does. An
explicitly configured `BUDGET_MAX_W` is used as written and is never clipped down to a
detected figure, though you do get a warning naming both numbers. For scripted or
diagnostic use, `$THERMAL_GUARD_ASSUME_STOCK_W` overrides detection outright; the test
suite uses it to pin the rating so its physics assertions produce identical numbers on
a bare CI runner and on a laptop with real RAPL.

---

## Requirements

bash 4+, coreutils, `logger` (util-linux, optional — falls back to the trace file).
systemd optional. Root to cap power; `--detect` works unprivileged.

`curl` **or** `wget` — optional, and only for weather adaptation. Without either,
thermal-guard starts normally and runs on `AMBIENT_FALLBACK_C`. There is no `jq`
dependency and there will not be one.

## Contributing

Reports from hardware I do not have are the most useful contribution — especially AMD,
`acpi-cpufreq` systems, and machines with an unusual Tjmax. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
