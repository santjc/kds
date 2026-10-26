import Darwin
import Foundation

/// The kinds of background process that coding agents and browser automation leave around.
public enum BackgroundKind: String, Sendable, CaseIterable {
  /// A Claude Code or Codex CLI session. Listed so its age and size are visible, never
  /// part of Kill All: it is usually the agent you are talking to.
  case agentSession
  /// Chrome or Chromium started headless or under automation (Playwright, Puppeteer).
  case automatedBrowser
  /// Vercel's `agent-browser` CLI and its daemon.
  case agentBrowser
  /// A Model Context Protocol server, usually spawned over stdio by an agent.
  case mcpServer
  /// A detached process whose command line points into an agent's working area.
  case agentLeftover
}

/// Who a background process belongs to, which decides whether Kill All may touch it.
public enum BackgroundOwnership: Sendable, Hashable {
  /// Descends from a live agent session; killing it breaks that session's tools.
  case agent(String)
  /// Reparented to launchd: whatever started it is gone, or it daemonised on purpose.
  case detached
  /// Has a live parent that is not an agent, such as a terminal or an IDE.
  case attached
}

public struct BackgroundProcess: Identifiable, Sendable, Hashable {
  public let kind: BackgroundKind
  public let name: String
  /// Launcher or driver, such as `npm`, `uv` or `Playwright`. Empty when unknown.
  public let detail: String
  public let pid: Int32
  public let startDate: Date
  public let ownership: BackgroundOwnership
  /// The root plus same-kind descendants folded into it (`npm exec` → `node`), so a
  /// kill does not strand the real worker.
  public let terminationPIDs: [Int32]
  /// The root and every descendant that is not its own row, so a browser's renderers
  /// count against the browser.
  public let usagePIDs: [Int32]

  public var id: String { "\(pid):\(startDate.timeIntervalSince1970)" }

  /// Clean Up only takes what nothing is using: detached processes whose parent is gone.
  /// Never an agent session, never anything an agent owns, and never something with a
  /// live parent — a headless browser under a running `playwright test` is in use.
  public var isKillAllEligible: Bool {
    kind != .agentSession && ownership == .detached
  }

  public init(
    kind: BackgroundKind, name: String, detail: String, pid: Int32, startDate: Date,
    ownership: BackgroundOwnership, terminationPIDs: [Int32], usagePIDs: [Int32]
  ) {
    self.kind = kind
    self.name = name
    self.detail = detail
    self.pid = pid
    self.startDate = startDate
    self.ownership = ownership
    self.terminationPIDs = terminationPIDs
    self.usagePIDs = usagePIDs
  }
}

public struct BackgroundProcessClassifier: Sendable {
  struct Match: Equatable {
    let kind: BackgroundKind
    let name: String
    let detail: String
  }

  private let currentUID: UInt32
  private let ownPID: Int32

  public init(currentUID: UInt32 = getuid(), ownPID: Int32 = getpid()) {
    self.currentUID = currentUID
    self.ownPID = ownPID
  }

  /// Groups the process table into rows: one per matched process tree, oldest first.
  public func classify(_ table: [ProcessSnapshot]) -> [BackgroundProcess] {
    let tree = ProcessTree(table)

    var matches: [Int32: Match] = [:]
    for process in table where process.ownerUID == currentUID && process.pid != ownPID {
      if let match = Self.match(process) { matches[process.pid] = match }
    }

    // A match folds into the top-most ancestor of the same kind: `npm exec x-mcp` and
    // the `node x-mcp` it spawns are one server, not two.
    var rootOf: [Int32: Int32] = [:]
    for (pid, match) in matches {
      rootOf[pid] = tree.ancestors(of: pid).last { matches[$0]?.kind == match.kind } ?? pid
    }
    let roots = Set(rootOf.values)

    return roots.compactMap { root -> BackgroundProcess? in
      guard let process = tree.byPID[root], let match = matches[root] else { return nil }

      let folded = rootOf.filter { $0.value == root }.map(\.key)
      let ownerAgent = tree.ancestors(of: root).lazy.compactMap { pid in
        matches[pid].flatMap { $0.kind == .agentSession ? $0.name : nil }
      }.first
      let ownership: BackgroundOwnership =
        if let ownerAgent { .agent(ownerAgent) } else if process.parentPID == 1 { .detached } else {
          .attached
        }

      return BackgroundProcess(
        kind: match.kind, name: match.name, detail: match.detail, pid: root,
        startDate: process.startDate, ownership: ownership,
        terminationPIDs: folded.sorted(),
        usagePIDs: tree.subtree(of: root, stoppingAt: roots.subtracting([root])))
    }
    .sorted {
      if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
      return $0.pid < $1.pid
    }
  }

  // MARK: - Matching

  private static let browserExecutables: [String: String] = [
    "google chrome": "Chrome", "google chrome for testing": "Chrome", "chrome": "Chrome",
    "chromium": "Chromium", "chrome-headless-shell": "Chromium", "headless_shell": "Chromium",
    "microsoft edge": "Edge", "brave browser": "Brave",
  ]

  private static let automationFlags = [
    "--remote-debugging-port", "--remote-debugging-pipe", "--enable-automation",
  ]

  private static let interpreters: Set<String> = [
    "node", "bun", "deno", "python", "python3", "perl", "ruby", "sh", "bash", "zsh",
  ]

  /// Markers of an agent's working area in a command line, with a human label.
  private static let agentAreas: [(marker: String, label: String)] = [
    ("/.claude/", "Claude"), ("/.codex/", "Codex"), ("codex-uv-cache", "Codex"),
    ("/conductor/workspaces/", "Conductor"),
  ]

  static func match(_ process: ProcessSnapshot) -> Match? {
    let executable = process.executableName.lowercased()
    let arguments = process.arguments
    let commandLine = arguments.joined(separator: " ").lowercased()

    // Chromium helpers (renderer, GPU, network) are part of their browser's row.
    if arguments.contains(where: { $0.hasPrefix("--type=") }) { return nil }

    // Identity comes from the executable, or the script an interpreter runs — never from
    // any argument, or `grep agent-browser` would be a browser KDS offers to kill.
    let script = script(of: process)?.lowercased()
    if executable == "claude" || script?.contains("@anthropic-ai/claude-code/") == true {
      return Match(kind: .agentSession, name: "Claude Code", detail: "")
    }
    if executable == "codex" || script?.contains("@openai/codex/") == true {
      let detail = arguments.contains("app-server") ? "app-server" : ""
      return Match(kind: .agentSession, name: "Codex", detail: detail)
    }

    if executable == "agent-browser" || script?.contains("/agent-browser/") == true
      || script.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "agent-browser"
    {
      return Match(kind: .agentBrowser, name: "agent-browser", detail: "")
    }

    if let browser = browserExecutables[executable] {
      let headless = arguments.contains { $0 == "--headless" || $0.hasPrefix("--headless=") }
      let automated = arguments.contains { argument in
        automationFlags.contains { argument == $0 || argument.hasPrefix($0 + "=") }
      }
      guard headless || automated else { return nil }
      let driver =
        commandLine.contains("ms-playwright") || commandLine.contains("playwright")
        ? "Playwright" : commandLine.contains("puppeteer") ? "Puppeteer" : ""
      return Match(
        kind: .automatedBrowser, name: "\(headless ? "Headless" : "Automated") \(browser)",
        detail: driver)
    }

    // App bundles and the OS ship their own helpers; none of them are agent leftovers.
    let path = process.executablePath
    if path.contains(".app/Contents/") || path.hasPrefix("/System/")
      || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    {
      return nil
    }

    // `npm exec` rewrites its process title into one argument, so split on spaces too.
    let tokens = arguments.lazy.flatMap { $0.split(separator: " ").map(String.init) }
    if let server = tokens.compactMap(mcpServerName).first {
      return Match(kind: .mcpServer, name: server, detail: launcher(of: process))
    }

    if process.parentPID == 1,
      let area = agentAreas.first(where: {
        commandLine.contains($0.marker) || path.contains($0.marker)
      })
    {
      return Match(kind: .agentLeftover, name: leftoverName(of: process), detail: area.label)
    }

    return nil
  }

  /// The server's name if `argument` names an MCP server: a token with `mcp` as a whole
  /// word, such as `qa-mcp`, `mcp-server-fetch` or `@playwright/mcp@latest`.
  /// Flags are skipped so an agent's `--mcp-config` does not make it a server.
  public static func mcpServerName(_ argument: String) -> String? {
    guard !argument.hasPrefix("-") else { return nil }
    let lowered = argument.lowercased()
    guard lowered.contains("modelcontextprotocol") || containsMCPWord(lowered) else {
      return nil
    }

    // Scoped packages keep their scope; paths reduce to their last component.
    let name: String
    if argument.hasPrefix("@"), let slash = argument.firstIndex(of: "/") {
      let rest = argument[argument.index(after: slash)...]
      let package = rest.split(separator: "@", maxSplits: 1).first.map(String.init) ?? String(rest)
      name = String(argument[..<slash]) + "/" + package
    } else {
      let last = URL(fileURLWithPath: argument).lastPathComponent
      name = last.split(separator: "@", maxSplits: 1).first.map(String.init) ?? last
    }
    return name.isEmpty ? nil : name
  }

  private static func containsMCPWord(_ value: String) -> Bool {
    let separators: Set<Character> = ["-", "_", "@", "/", ".", " "]
    var searchStart = value.startIndex
    while let range = value.range(of: "mcp", range: searchStart..<value.endIndex) {
      let before = range.lowerBound == value.startIndex || separators.contains(value[value.index(before: range.lowerBound)])
      let after = range.upperBound == value.endIndex || separators.contains(value[range.upperBound])
      if before && after { return true }
      searchStart = range.upperBound
    }
    return false
  }

  private static func launcher(of process: ProcessSnapshot) -> String {
    if let first = process.arguments.first, first.hasPrefix("npm exec") { return "npm" }
    let executable = process.executableName
    return executable == "python3" ? "python" : executable
  }

  /// The script an interpreter is running: its first non-flag argument.
  private static func script(of process: ProcessSnapshot) -> String? {
    guard interpreters.contains(process.executableName.lowercased()) else { return nil }
    return process.arguments.dropFirst().first { !$0.hasPrefix("-") }
  }

  /// Interpreters name the script, not themselves: `perl …/exiftool` reads as `exiftool`.
  private static func leftoverName(of process: ProcessSnapshot) -> String {
    script(of: process).map { URL(fileURLWithPath: $0).lastPathComponent } ?? process.executableName
  }
}

public enum ElapsedTime {
  /// How long ago `start` was, in the largest unit that fits: `<1m`, `42m`, `5h`, `3d`, `2w`.
  public static func short(since start: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(start))
    let minute = 60.0
    let hour = 60 * minute
    let day = 24 * hour
    let week = 7 * day

    switch seconds {
    case ..<minute: return "<1m"
    case ..<hour: return "\(Int(seconds / minute))m"
    case ..<day: return "\(Int(seconds / hour))h"
    case ..<week: return "\(Int(seconds / day))d"
    default: return "\(Int(seconds / week))w"
    }
  }

  /// The spoken form for VoiceOver and tooltips: "started 3 days ago".
  public static func spoken(since start: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "started " + formatter.localizedString(for: start, relativeTo: now)
  }
}
