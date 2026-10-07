# Architecture

KDS has a native SwiftUI shell and a UI-independent core.

```text
NSStatusItem image → MascotAnimator → CPULoadSampler → host_processor_info
NSStatusItem click → MenuPanel → KDSMenuView (gauges · server table · background · footer)
NSStatusItem right click → NSMenu (Launch at Login · Quit)
        ↓                        ↓                          ↓
   PortStore              BackgroundStore            SystemUsageStore
        ↓                        ↓                          ↓
 PortSource             ProcessTableSource          SystemMetricsSampling
 ProcessInspecting      BackgroundProcessClassifier
 ProcessClassifier      ProcessInspecting
 ProcessUsageSampling   ProcessUsageSampling
 ProcessTerminating     ProcessTerminating
        ↓                        ↓                          ↓
 lsof · proc_pid_rusage   sysctl KERN_PROC · KERN_PROCARGS2   host_* · IOAccelerator / IOGPU
        ↓
  Darwin.kill
```

## Boundaries

- `KDSCore` owns value types, `lsof` and `ps` parsing, process inspection, classification, host metrics, and signal delivery.
- `KDS` owns SwiftUI, visible-only refresh lifecycle, cached enrichment, user overrides, and confirmation flows.
- System access is behind small protocols so parsing and policy remain deterministic and testable.
- `ProcessTerminating` revalidates the PID and port immediately before signalling.

## Panel layout

The menu bar item is an AppKit `NSStatusItem`, not SwiftUI's `MenuBarExtra`, because `MenuBarExtra` cannot tell a right click from a left one. Left click shows a borderless, non-activating `MenuPanel` with the popover material, hung from the menu bar; a click anywhere else or Escape closes it. Closing tears the SwiftUI hosting view down, so the views' `onDisappear` stops every scan loop. Right click shows an `NSMenu` with Launch at Login and Quit.

The panel has a fixed width and no fixed height. Header, gauges, and footer are intrinsic; the server table is a `SelfSizingScrollView` that adopts its content's measured height and only scrolls once it exceeds `MenuMetrics.maxContentHeight`. Collapsing the Other Listeners section therefore shrinks the whole window, and expanding it grows it.

Three gauges sit side by side — CPU, GPU, RAM — over a table whose columns are port, name, CPU%, RAM%, and the row actions. Header and rows share the widths in `MenuMetrics`, so the columns line up without a grid container.

## Scan lifecycle

Opening the menu starts the 1-second usage sampler and an immediate scan, followed by a two-second refresh loop. Closing the menu cancels both.

`lsof` runs without a shell, has a two-second timeout, and is parsed by a pure function that filters by UID and merges IPv4/IPv6 records sharing a PID and port.

System CPU is a delta between two `host_processor_info` readings, so the sampler primes one reading before publishing a value. Memory used is `active + wired + compressed` pages, matching Activity Monitor's "Memory Used". GPU comes from the `PerformanceStatistics` dictionary of the `IOAccelerator`/`IOGPU` registry entries; a machine that publishes no counter reads as `—` rather than `0%`.

Per-process CPU and RAM come from `proc_pid_rusage`, sampled once per scan alongside `lsof`. CPU is a delta of user plus system time over elapsed time, so it is instantaneous like Activity Monitor's column and can exceed 100% on multiple cores — not `ps`'s `%cpu`, which averages over the whole process lifetime. The previous reading is dropped for any PID that disappears, so a recycled PID cannot inherit a stale baseline.

There is no per-process GPU column. macOS exposes no public per-PID GPU counter, so GPU stays machine-wide, in the gauge only.

## Menu bar mascot

`MascotAnimator` is the only always-on work. It samples CPU ticks every two seconds — not the full `SystemUsage`, which also reads memory and the GPU registry — and maps the percentage onto six `CPULoadLevel` bands taken from the design boards (0–20–40–60–75–90–100). Leaving a band needs a three-point margin past its edge, so load hovering on a boundary does not flicker the icon. Each band has its own frame set and tempo, from 0.5 s per frame idle to 0.07 s critical. The timer runs in `.common` mode so the icon keeps moving while the panel is open, and stops entirely under Reduce Motion.

Frames are template images (alpha is ink), so the menu bar tints them for light, dark and tinted appearances. `Scripts/cut-sprites.swift` produces them from the boards in `Resources/Mascot`: it finds the heads, assigns droplets and motion marks to the nearest head, anchors every frame to its slot on a fitted grid so the drawn shake survives, and scales each state by face width so the mascot stays one size across moods. The packaged app carries them in `Contents/Resources/Sprites`; `swift run` finds them in the SwiftPM resource bundle.

## Background processes

`SysctlProcessTable` reads the current user's processes with `KERN_PROC_UID` and their argv with `KERN_PROCARGS2`, caching argv by PID and start time. `BackgroundProcessClassifier` is a pure function over that table:

1. Chromium helpers (`--type=…`) never match; they count toward their browser's row.
2. `claude`, `codex` and their npm packages are agent sessions; `agent-browser` is browser automation; Chrome or Chromium with `--headless` or a remote-debugging/automation flag is an automated browser.
3. App-bundle and OS executables stop matching here, so an IDE's helpers are not mistaken for agent tools.
4. Any non-flag argument with `mcp` as a whole word (`qa-mcp`, `mcp-server-fetch`, `@playwright/mcp`) is an MCP server. Flags are skipped, so `--mcp-config` does not make an agent a server.
5. A process reparented to launchd whose command line points into `.claude/`, `.codex/` or a Conductor workspace is an agent leftover.

A match folds into its top-most same-kind ancestor (`npm exec x-mcp` and the `node` it spawns are one row), and termination signals the folded workers before their launcher. Usage sums the root and every descendant that is not its own row. A row descending from a live agent session is owned by it, and Clean Up skips it; agent sessions themselves always need a confirmation. Kills re-read the table and only signal PIDs whose start time still matches the scan.

## Classification

Kill All eligibility is conservative:

1. KDS itself, other users, system paths, and app-bundle processes are protected.
2. Databases and recognized local services remain visible but excluded.
3. Processes inside detected project directories and known development runtimes are included.
4. Unknown processes remain excluded.
5. Path-based user overrides are applied before automatic classification, except for KDS itself.

## Termination

Each action re-scans and requires the target to still be there: the selected PID must still own the selected port, under the current UID. Signals are sent once per PID. KDS never terminates a process group or follows parent/child relationships, which prevents it from closing terminals and unrelated jobs.
