# Contributing

## Testing on your hardware

The most useful contribution is a report from hardware I do not have. Run:

```bash
./thermal-guard --detect
```

and open an issue with the output plus your machine model. Especially wanted:

- **AMD** — confirm it degrades cleanly to monitor-only
- **`acpi-cpufreq`** systems (no `intel_pstate`)
- **Multi-socket** or machines where `intel-rapl:0` is not `package-0`
- **BIOS-locked RAPL** — it should say so, not silently do nothing
- Machines with **Tjmax other than 100/105 °C**

## Ground rules

- POSIX-ish bash, no new runtime dependencies beyond bash/coreutils/util-linux.
- Nothing vendor- or model-specific in the code. Discover it at runtime, by name.
  `hwmon*` and `thermal_zone*` indices are not stable across reboots.
- Distinguish "hardware does not support this" from "we lack permission" in every
  diagnostic. Conflating them sends people hunting for a missing driver when they
  forgot sudo.
- Defaults must be safe. Installing must not change machine behaviour until the
  user opts in.
- `shellcheck -S warning` clean.

## Shell gotchas this codebase has already been bitten by

- **Never call a stateful function via `$(...)`** — command substitution runs in a
  subshell and the state update is silently discarded.
- **`mawk`: an uninitialised variable used as an array subscript becomes `""`, not
  `0`.** `arr[n]=x; n++` puts the first element at index `""`; use `arr[n++]=x` or
  initialise in `BEGIN`.
- **`pkill -f` matches its own command line**, including patterns inside `echo`
  strings. Kill by PID.
