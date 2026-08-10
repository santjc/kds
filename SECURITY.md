# Security

KDS is local-only. It has no analytics, remote API, embedded web content, updater, or privileged helper.

The app is distributed outside the Mac App Store and is not sandboxed so it can inspect current-user listeners. It never requests administrator privileges and cannot terminate processes owned by another user under normal macOS permissions.

Please report vulnerabilities through a private GitHub security advisory rather than a public issue.
