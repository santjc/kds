# KDS — Kill Dev Servers

KDS is a lightweight, native macOS menu bar app for reclaiming the resources your development work leaves behind: local servers still holding ports, and processes still holding memory.

## Features

**At a glance**

- Machine-wide CPU, GPU, and RAM bars across the top of the panel.
- The panel sizes itself to its content — collapsed sections keep it small, expanding one grows it.

**The server table**

- Finds TCP listeners owned by the current user.
- One row per listener: port, name, CPU%, RAM%, and a kill button.
- Per-process CPU and RAM come from `proc_pid_rusage`, sampled as a delta, so CPU is instantaneous and can exceed 100% across cores.
- There is no per-process GPU column: macOS publishes no public per-PID GPU counter, so GPU is reported machine-wide only.
- Opens or copies `localhost` URLs from the row menu.
- Sends `SIGTERM` to one server or a reviewed Kill All selection.
- Protects system apps, GUI apps, databases, and unknown listeners by default.

**Throughout**

- Polls only while the menu is open.
- Uses no admin privileges, telemetry, accounts, or runtime dependencies.

## Requirements

- macOS 13 Ventura or newer.
- Apple Silicon or Intel.

## Install

Download `KDS.zip` from GitHub Releases, move `KDS.app` to Applications, then Control-click the app and choose **Open** on first launch.

Releases are currently ad-hoc signed rather than Apple-notarized, so the first launch requires explicit Gatekeeper approval.

## Develop

```sh
swift build --product KDS
swift run KDS
```

Build a universal `.app` bundle:

```sh
./Scripts/build-app.sh
open Artifacts/KDS.app
```

Run the core test suite, including non-destructive real `lsof`, `proc_pid_rusage`, and Mach host scans:

```sh
swift run KDSCoreTests
```

## Safety model

KDS executes `/usr/sbin/lsof` directly with fixed arguments, reads system CPU and memory through Mach host calls, GPU through the IOKit registry, per-process usage through `proc_pid_rusage`, and calls the Darwin `kill` API directly. It never constructs shell commands or requests `sudo`. There is deliberately no "purge" or "free memory" button: that requires root and reclaims nothing meaningful on modern macOS.

Kill All includes only high-confidence development processes or executables explicitly included by the user. It previews the unique PIDs and ports, sends `SIGTERM`, and offers a separately confirmed `SIGKILL` only for survivors.

KDS is intentionally not sandboxed because a sandboxed app cannot inspect and signal unrelated processes. It filters the list to the current Unix user and revalidates the PID and port immediately before termination, so a recycled PID cannot be signalled by mistake.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details.

## License

MIT

