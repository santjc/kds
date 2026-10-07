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

  /// Kill All only takes what nobody is using: never an agent session, never anything
  /// an agent session still owns.
  public var isKillAllEligible: Bool {
    guard kind != .agentSession else { return false }
    if case .agent = ownership { return false }
    return true
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
    let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var children: [Int32: [Int32]] = [:]
    for process in table { children[process.parentPID, default: []].append(process.pid) }

    var matches: [Int32: Match] = [:]
    for process in table where process.ownerUID == currentUID && process.pid != ownPID {
      if let match = Self.match(process) { matches[process.pid] = match }
    }

    func ancestors(of pid: Int32) -> [Int32] {
      var chain: [Int32] = []
      var seen: Set<Int32> = [pid]
      var current = byPID[pid]?.parentPID
      while let parent = current, parent > 1, seen.insert(parent).inserted {
        chain.append(parent)
        current = byPID[parent]?.parentPID
      }
      return chain
    }

    // A match folds into the top-most ancestor of the same kind: `npm exec x-mcp` and
    // the `node x-mcp` it spawns are one server, not two.
    var rootOf: [Int32: Int32] = [:]
    for (pid, match) in matches {
      rootOf[pid] = ancestors(of: pid).last { matches[$0]?.kind == match.kind } ?? pid
    }
    let roots = Set(rootOf.values)

    return roots.compactMap { root -> BackgroundProcess? in
      guard let process = byPID[root], let match = matches[root] else { return nil }

      let folded = rootOf.filter { $0.value == root }.map(\.key)
      var usage: [Int32] = []
      var queue = [root]
      while let pid = queue.popLast() {
        usage.append(pid)
        for child in children[pid] ?? [] where !roots.contains(child) {
          queue.append(child)
        }
      }

      let ownerAgent = ancestors(of: root).lazy.compactMap { pid in
        matches[pid].flatMap { $0.kind == .agentSession ? $0.name : nil }
      }.first
      let ownership: BackgroundOwnership =
        if let ownerAgent { .agent(ownerAgent) } else if process.parentPID == 1 { .detached } else {
          .attached
        }

      return BackgroundProcess(
        kind: match.kind, name: match.name, detail: match.detail, pid: root,
        startDate: process.startDate, ownership: ownership,
        terminationPIDs: folded.sorted(), usagePIDs: usage.sorted())
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

    if executable == "claude" || commandLine.contains("@anthropic-ai/claude-code") {
      return Match(kind: .agentSession, name: "Claude Code", detail: "")
    }
    if executable == "codex" || commandLine.contains("@openai/codex") {
      let detail = arguments.contains("app-server") ? "app-server" : ""
      return Match(kind: .agentSession, name: "Codex", detail: detail)
    }

    if executable == "agent-browser" || commandLine.contains("agent-browser") {
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

  /// Interpreters name the script, not themselves: `perl …/exiftool` reads as `exiftool`.
  private static func leftoverName(of process: ProcessSnapshot) -> String {
    let executable = process.executableName
    if interpreters.contains(executable.lowercased()),
      let script = process.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
    {
      return URL(fileURLWithPath: script).lastPathComponent
    }
    return executable
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
