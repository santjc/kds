# Architecture

KDS has a native SwiftUI shell and a UI-independent core.

```text
MenuBarExtra / views
        ↓
PortStore (@MainActor)
        ↓
PortSource · ProcessInspecting · ProcessTerminating
        ↓
lsof · proc_pidpath · Darwin.kill
```

## Boundaries

- `KDSCore` owns value types, `lsof` parsing, process inspection, classification, and signal delivery.
- `KDS` owns SwiftUI, visible-only refresh lifecycle, cached enrichment, user overrides, and confirmation flows.
- System access is behind small protocols so parsing and policy remain deterministic and testable.

## Scan lifecycle

Opening the menu starts an immediate scan followed by a two-second refresh loop. Closing it cancels the task. Identical PIDs reuse cached process details; a changed port fingerprint invalidates the cache.

`lsof` runs without a shell, has a two-second timeout, and returns field-oriented output. The parser filters by UID and merges IPv4/IPv6 records sharing a PID and port.

## Classification

Kill All eligibility is conservative:

1. KDS itself, other users, system paths, and app-bundle processes are protected.
2. Databases and recognized local services remain visible but excluded.
3. Processes inside detected project directories and known development runtimes are included.
4. Unknown processes remain excluded.
5. Path-based user overrides are applied before automatic classification, except for KDS itself.

## Termination

Each action re-scans and requires the selected PID to still own the selected port. Signals are sent once per PID. KDS never terminates a process group or follows parent/child relationships, which prevents it from closing terminals and unrelated jobs.

