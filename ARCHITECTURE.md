# Architecture

KDS has a native SwiftUI shell and a UI-independent core.

```text
MenuBarExtra → KDSMenuView (CPU · GPU · RAM gauges · server table · footer)
        ↓                                         ↓
   PortStore                               SystemUsageStore
        ↓                                         ↓
 PortSource                               SystemMetricsSampling
 ProcessInspecting
 ProcessClassifier
 ProcessUsageSampling
 ProcessTerminating
        ↓                                         ↓
      lsof                    host_processor_info · host_statistics64
 proc_pid_rusage                     IOAccelerator / IOGPU counters
        ↓
  Darwin.kill
```

## Boundaries

- `KDSCore` owns value types, `lsof` and `ps` parsing, process inspection, classification, host metrics, and signal delivery.
- `KDS` owns SwiftUI, visible-only refresh lifecycle, cached enrichment, user overrides, and confirmation flows.
- System access is behind small protocols so parsing and policy remain deterministic and testable.
- `ProcessTerminating` revalidates the PID and port immediately before signalling.

## Panel layout

The panel has a fixed width and no fixed height. Header, gauges, and footer are intrinsic; the server table is a `SelfSizingScrollView` that adopts its content's measured height and only scrolls once it exceeds `MenuMetrics.maxContentHeight`. Collapsing the Other Listeners section therefore shrinks the whole window, and expanding it grows it.

Three gauges sit side by side — CPU, GPU, RAM — over a table whose columns are port, name, CPU%, RAM%, and the row actions. Header and rows share the widths in `MenuMetrics`, so the columns line up without a grid container.

## Scan lifecycle

Opening the menu starts the 1-second usage sampler and an immediate scan, followed by a two-second refresh loop. Closing the menu cancels both.

`lsof` runs without a shell, has a two-second timeout, and is parsed by a pure function that filters by UID and merges IPv4/IPv6 records sharing a PID and port.

System CPU is a delta between two `host_processor_info` readings, so the sampler primes one reading before publishing a value. Memory used is `active + wired + compressed` pages, matching Activity Monitor's "Memory Used". GPU comes from the `PerformanceStatistics` dictionary of the `IOAccelerator`/`IOGPU` registry entries; a machine that publishes no counter reads as `—` rather than `0%`.

Per-process CPU and RAM come from `proc_pid_rusage`, sampled once per scan alongside `lsof`. CPU is a delta of user plus system time over elapsed time, so it is instantaneous like Activity Monitor's column and can exceed 100% on multiple cores — not `ps`'s `%cpu`, which averages over the whole process lifetime. The previous reading is dropped for any PID that disappears, so a recycled PID cannot inherit a stale baseline.

There is no per-process GPU column. macOS exposes no public per-PID GPU counter, so GPU stays machine-wide, in the gauge only.

## Classification

Kill All eligibility is conservative:

1. KDS itself, other users, system paths, and app-bundle processes are protected.
2. Databases and recognized local services remain visible but excluded.
3. Processes inside detected project directories and known development runtimes are included.
4. Unknown processes remain excluded.
5. Path-based user overrides are applied before automatic classification, except for KDS itself.

## Termination

Each action re-scans and requires the target to still be there: the selected PID must still own the selected port, under the current UID. Signals are sent once per PID. KDS never terminates a process group or follows parent/child relationships, which prevents it from closing terminals and unrelated jobs.
