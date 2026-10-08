# KDS — Kill Dev Servers

KDS is a lightweight, native macOS menu bar app for reclaiming the resources your development work leaves behind: local servers still holding ports, and processes still holding memory.

## Features

**At a glance**

- The menu bar mascot changes mood with CPU load — idle, active, busy, hot, very hot, critical — and animates faster as load climbs. Reduce Motion holds a still frame per mood.
- Machine-wide CPU, GPU, and RAM bars across the top of the panel.
- Left click opens the panel; right click (or control-click) opens Launch at Login and Quit.
- The panel sizes itself to its content — collapsed sections keep it small, expanding one grows it.

**The server table**

- Finds TCP listeners owned by the current user.
- One row per listener: port, name, CPU%, RAM%, and a kill button.
- Per-process CPU and RAM come from `proc_pid_rusage`, sampled as a delta, so CPU is instantaneous and can exceed 100% across cores.
- There is no per-process GPU column: macOS publishes no public per-PID GPU counter, so GPU is reported machine-wide only.
- Opens or copies `localhost` URLs from the row menu.
- Sends `SIGTERM` to one server or a reviewed Kill All selection.
- Protects system apps, GUI apps, databases, and unknown listeners by default.

**Background processes**

- Lists what coding agents and browser automation leave running: headless or automated Chrome (Playwright, Puppeteer), `agent-browser`, MCP servers, Claude Code and Codex sessions, and detached processes started from an agent's worktree.
- Each row shows how long ago it started (`5m`, `3h`, `2d`, `1w`), its CPU and RAM summed over its process tree, and who owns it: a live agent, a parent, or nobody (detached).
- Clean Up terminates only what no live agent is using. Agent sessions, and anything they still own, need a confirmation and are never bulk-killed.

**Throughout**

- Polls only while the menu is open. The menu bar icon samples CPU alone, every two seconds.
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

Re-cut the mascot frames after editing the spritesheets in `Resources/Mascot`:

```sh
swift Scripts/cut-sprites.swift Resources/Mascot Sources/KDS/Sprites
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

KDS executes `/usr/sbin/lsof` directly with fixed arguments, reads system CPU and memory through Mach host calls, GPU through the IOKit registry, per-process usage through `proc_pid_rusage`, the process table and argv through `sysctl`, and calls the Darwin `kill` API directly. It never constructs shell commands or requests `sudo`. There is deliberately no "purge" or "free memory" button: that requires root and reclaims nothing meaningful on modern macOS.

Kill All includes only high-confidence development processes or executables explicitly included by the user. It previews the unique PIDs and ports, sends `SIGTERM`, and offers a separately confirmed `SIGKILL` only for survivors.

KDS is intentionally not sandboxed because a sandboxed app cannot inspect and signal unrelated processes. It filters the list to the current Unix user and revalidates the PID and port immediately before termination, so a recycled PID cannot be signalled by mistake.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details.

## License

MIT

