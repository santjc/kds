# KDS — Kill Dev Servers

KDS is a lightweight, native macOS menu bar app for reclaiming the resources your development work leaves behind: local servers still holding ports, and processes still holding memory.

## Features

**At a glance**

- Live CPU and memory usage bars in the menu panel.
- The panel sizes itself to its content — collapsed sections keep it small, expanding one grows it.

**Servers tab**

- Finds TCP listeners owned by the current user.
- Shows port, process, PID, and project directory.
- Opens or copies `localhost` URLs.
- Sends `SIGTERM` to one server or a reviewed Kill All selection.
- Protects system apps, GUI apps, databases, and unknown listeners by default.

**Memory tab**

- Lists the current user's largest memory consumers, grouped into development processes and everything else.
- Terminates a process from the list; anything outside the development group asks for confirmation first.
- Protects KDS itself, other users' processes, macOS system paths, and critical processes such as `WindowServer` and `Finder`.
- Sizes come from `ps` RSS, which counts shared framework pages against every process that maps them, so figures read a little above Activity Monitor's Memory column.

**Throughout**

- Polls only while the menu is open, and only for the tab you are looking at.
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

Run the core test suite, including non-destructive real `lsof`, `ps`, and Mach host scans:

```sh
swift run KDSCoreTests
```

## Safety model

KDS executes `/usr/sbin/lsof` and `/bin/ps` directly with fixed arguments, reads CPU and memory through Mach host calls, and calls the Darwin `kill` API directly. It never constructs shell commands or requests `sudo`. There is deliberately no "purge" or "free memory" button: that requires root and reclaims nothing meaningful on modern macOS.

Kill All includes only high-confidence development processes or executables explicitly included by the user. It previews the unique PIDs and ports, sends `SIGTERM`, and offers a separately confirmed `SIGKILL` only for survivors.

KDS is intentionally not sandboxed because a sandboxed app cannot inspect and signal unrelated processes. It filters every list to the current Unix user and revalidates immediately before termination — the PID and port on the Servers tab, the PID and executable path on the Memory tab, so a recycled PID cannot be signalled by mistake.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details.

## License

MIT

