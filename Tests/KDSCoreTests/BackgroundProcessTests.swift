import Foundation
import KDSCore

private let uid: UInt32 = 501
private let classifier = BackgroundProcessClassifier(currentUID: uid, ownPID: 999)
private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func process(
  _ pid: Int32, parent: Int32 = 50, path: String, _ arguments: [String] = [],
  owner: UInt32 = uid, started: Date = epoch
) -> ProcessSnapshot {
  ProcessSnapshot(
    pid: pid, parentPID: parent, ownerUID: owner, startDate: started,
    executablePath: path, arguments: arguments.isEmpty ? [path] : arguments)
}

private let terminal = process(50, parent: 1, path: "/bin/zsh")

let backgroundProcessTests: [TestCase] = [
  TestCase("finds headless Chrome and folds its helpers into one row") {
    let chrome = "/Users/me/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
    let rows = classifier.classify([
      terminal,
      process(100, path: chrome, [chrome, "--headless=new", "--user-data-dir=/tmp/x"]),
      process(101, parent: 100, path: chrome, [chrome, "--type=renderer"]),
      process(102, parent: 100, path: chrome, [chrome, "--type=gpu-process"]),
    ])
    try expect(rows.count == 1)
    try expect(rows[0].kind == .automatedBrowser)
    try expect(rows[0].name == "Headless Chromium")
    try expect(rows[0].detail == "Playwright")
    try expect(rows[0].terminationPIDs == [100])
    try expect(rows[0].usagePIDs == [100, 101, 102], "renderers count against the browser")
  },
  TestCase("ignores an everyday Chrome window") {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    try expect(classifier.classify([terminal, process(100, path: chrome)]).isEmpty)
  },
  TestCase("names MCP servers from their package, folding npm exec into node") {
    let rows = classifier.classify([
      terminal,
      process(200, path: "/opt/homebrew/bin/node", ["npm exec ui-ux-pro-mcp --stdio"]),
      process(201, parent: 200, path: "/opt/homebrew/bin/node", ["node", "/x/.bin/ui-ux-pro-mcp", "--stdio"]),
      process(210, path: "/opt/homebrew/bin/node", ["npx", "-y", "@playwright/mcp@latest"]),
      process(220, path: "/opt/homebrew/bin/uv", ["uv", "tool", "uvx", "mcp-server-fetch"]),
    ])
    try expect(rows.map(\.name) == ["ui-ux-pro-mcp", "@playwright/mcp", "mcp-server-fetch"])
    try expect(rows[0].detail == "npm")
    try expect(rows[0].terminationPIDs == [200, 201], "killing npm alone would strand node")
  },
  TestCase("does not mistake mcp inside other words or flags for a server") {
    try expect(BackgroundProcessClassifier.mcpServerName("--mcp-config") == nil)
    try expect(BackgroundProcessClassifier.mcpServerName("/usr/bin/mcpd") == nil)
    try expect(BackgroundProcessClassifier.mcpServerName("compcpu") == nil)
    try expect(BackgroundProcessClassifier.mcpServerName("qa-mcp@0.12.0") == "qa-mcp")
  },
  TestCase("keeps whatever a live agent owns out of Kill All") {
    let claude = "/Users/me/.local/bin/claude"
    let rows = classifier.classify([
      terminal,
      process(300, path: claude, [claude, "--mcp-config", "x.json"]),
      process(301, parent: 300, path: "/opt/homebrew/bin/bun", ["bun", "/tmp/qa-mcp"]),
      process(400, parent: 1, path: "/opt/homebrew/bin/bun", ["bun", "/tmp/qa-mcp"]),
    ])
    let session = try require(rows.first { $0.kind == .agentSession })
    let owned = try require(rows.first { $0.pid == 301 })
    let orphan = try require(rows.first { $0.pid == 400 })

    try expect(session.name == "Claude Code")
    try expect(!session.isKillAllEligible, "an agent session is never bulk-killed")
    try expect(owned.ownership == .agent("Claude Code"))
    try expect(!owned.isKillAllEligible)
    try expect(orphan.ownership == .detached)
    try expect(orphan.isKillAllEligible)
    try expect(session.usagePIDs == [300], "the session's MCP server is its own row")
  },
  TestCase("flags detached processes started from an agent worktree") {
    let rows = classifier.classify([
      process(
        500, parent: 1, path: "/usr/bin/perl",
        ["perl", "/Users/me/repo/.claude/worktrees/a1/exiftool", "-stay_open", "True"]),
      process(501, parent: 1, path: "/usr/bin/perl", ["perl", "/Users/me/tools/exiftool"]),
    ])
    try expect(rows.count == 1)
    try expect(rows[0].kind == .agentLeftover)
    try expect(rows[0].name == "exiftool")
    try expect(rows[0].detail == "Claude")
  },
  TestCase("skips itself, other users and app bundle helpers") {
    let rows = classifier.classify([
      process(999, path: "/x/agent-browser"),
      process(600, path: "/x/agent-browser", owner: 0),
      process(
        700, path: "/Applications/Code.app/Contents/Resources/copilot-runtime",
        ["copilot-runtime", "--headless", "some-mcp"]),
    ])
    try expect(rows.isEmpty)
  },
  TestCase("lists oldest first") {
    let rows = classifier.classify([
      process(800, path: "/x/agent-browser", started: epoch.addingTimeInterval(60)),
      process(801, path: "/x/agent-browser", started: epoch),
    ])
    try expect(rows.map(\.pid) == [801, 800])
  },
  TestCase("formats age in the largest unit that fits") {
    let cases: [(TimeInterval, String)] = [
      (30, "<1m"), (5 * 60, "5m"), (3 * 3600, "3h"), (2 * 86400, "2d"), (9 * 86400, "1w"),
      (30 * 86400, "4w"),
    ]
    for (elapsed, expected) in cases {
      let label = ElapsedTime.short(since: epoch, now: epoch.addingTimeInterval(elapsed))
      try expect(label == expected, "\(elapsed)s should read \(expected), got \(label)")
    }
  },
  TestCase("parses KERN_PROCARGS2 argv and stops before the environment") {
    var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
    buffer += Array("/bin/echo".utf8) + [0, 0, 0]
    buffer += Array("echo".utf8) + [0] + Array("hi there".utf8) + [0]
    buffer += Array("HOME=/Users/me".utf8) + [0]
    let parsed = try require(SysctlProcessTable.parseProcArgs(buffer))
    try expect(parsed.path == "/bin/echo")
    try expect(parsed.arguments == ["echo", "hi there"])
  },
]
