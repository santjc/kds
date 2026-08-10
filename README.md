# KDS — Kill Dev Servers

KDS is a lightweight, native macOS menu bar app for finding and terminating local development servers.

## Features

- Finds TCP listeners owned by the current user.
- Shows port, process, PID, and project directory.
- Opens or copies `localhost` URLs.
- Sends `SIGTERM` to one server or a reviewed Kill All selection.
- Protects system apps, GUI apps, databases, and unknown listeners by default.
- Performs no polling while its menu is closed.
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

Run the core test suite, including a non-destructive real `lsof` scan:

```sh
swift run KDSCoreTests
```

## Safety model

KDS executes `/usr/sbin/lsof` directly with fixed arguments and calls the Darwin `kill` API directly. It never constructs shell commands or requests `sudo`.

Kill All includes only high-confidence development processes or executables explicitly included by the user. It previews the unique PIDs and ports, sends `SIGTERM`, and offers a separately confirmed `SIGKILL` only for survivors.

KDS is intentionally not sandboxed because a sandboxed app cannot inspect and signal unrelated processes. It filters listeners to the current Unix user and revalidates the PID and port immediately before termination.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details.

## License

MIT

