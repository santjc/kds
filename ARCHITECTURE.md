# Architecture

KDS has a native SwiftUI shell and a UI-independent core.

```text
MenuBarExtra → KDSMenuView (gauges · Servers | Memory · footer)
        ↓                    ↓                    ↓
   PortStore            MemoryStore        SystemUsageStore
        ↓                    ↓                    ↓
 PortSource          ProcessMemorySource   SystemMetricsSampling
 ProcessInspecting   MemoryClassifier
 ProcessClassifier
        ╰──── ProcessTerminating ────╯
        ↓                    ↓                    ↓
      lsof                  ps          host_processor_info · host_statistics64
                                                  ↓
                                            Darwin.kill
```

## Boundaries

- `KDSCore` owns value types, `lsof` and `ps` parsing, process inspection, classification, host metrics, and signal delivery.
- `KDS` owns SwiftUI, visible-only refresh lifecycle, cached enrichment, user overrides, and confirmation flows.
- System access is behind small protocols so parsing and policy remain deterministic and testable.
- `ProcessTerminating` is shared by both tabs; each store revalidates its own way before signalling.

## Panel layout

The panel has a fixed width and no fixed height. Header, gauges, and footer are intrinsic; the tab content is a `SelfSizingScrollView` that adopts its content's measured height and only scrolls once it exceeds `MenuMetrics.maxContentHeight`. Collapsing a disclosure section therefore shrinks the whole window, and expanding one grows it.

## Scan lifecycle

Opening the menu starts the 1-second usage sampler and an immediate scan of the selected tab, followed by a two-second refresh loop. Switching tabs stops the outgoing loop before starting the incoming one, so `lsof` and `ps` never run concurrently. Closing the menu cancels everything.

`lsof` and `ps` run without a shell, have a two-second timeout, and are parsed by pure functions. The `lsof` parser filters by UID and merges IPv4/IPv6 records sharing a PID and port. The `ps` parser filters by UID and splits only the four leading numeric columns, so command paths containing spaces survive intact.

CPU is a delta between two `host_processor_info` readings, so the sampler primes one reading before publishing a value. Memory used is `active + wired + compressed` pages, matching Activity Monitor's "Memory Used".

## Classification

Kill All eligibility is conservative:

1. KDS itself, other users, system paths, and app-bundle processes are protected.
2. Databases and recognized local services remain visible but excluded.
3. Processes inside detected project directories and known development runtimes are included.
4. Unknown processes remain excluded.
5. Path-based user overrides are applied before automatic classification, except for KDS itself.

## Memory classification

`MemoryClassifier` mirrors those rules with one deliberate difference: a process inside an `.app` bundle is `other`, not `protected`. On the Servers tab a GUI app is never what you meant to kill; on the Memory tab a multi-gigabyte browser usually is. `other` still requires a confirmation dialog.

Protection is checked before overrides, so KDS itself, other users' processes, macOS system paths, and the critical-process list (`WindowServer`, `loginwindow`, `Finder`, `launchd`, and similar) cannot be included by an override. Overrides are keyed by executable path and share storage with the Servers tab.

There is no bulk kill on the Memory tab. Dev servers are known-restartable; arbitrary applications are not.

## Termination

Each action re-scans and requires the target to still be there: the Servers tab requires the selected PID to still own the selected port, the Memory tab requires the selected PID to still map the same executable path. Both require the current UID. Signals are sent once per PID. KDS never terminates a process group or follows parent/child relationships, which prevents it from closing terminals and unrelated jobs.
