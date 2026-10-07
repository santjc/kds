import Darwin
import Foundation

/// One process as the kernel reports it: identity, parentage, start time and argv.
public struct ProcessSnapshot: Sendable, Hashable {
  public let pid: Int32
  public let parentPID: Int32
  public let ownerUID: UInt32
  public let startDate: Date
  public let executablePath: String
  public let arguments: [String]

  public init(
    pid: Int32, parentPID: Int32, ownerUID: UInt32, startDate: Date,
    executablePath: String, arguments: [String]
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.ownerUID = ownerUID
    self.startDate = startDate
    self.executablePath = executablePath
    self.arguments = arguments
  }

  public var executableName: String {
    URL(fileURLWithPath: executablePath).lastPathComponent
  }
}

public protocol ProcessTableSource: Sendable {
  func snapshot() async -> [ProcessSnapshot]
}

/// Reads the current user's processes through `sysctl`, without a shell.
///
/// argv comes from `KERN_PROCARGS2`, which is one syscall per process. A process's argv
/// never changes, so it is cached by PID and start time; a recycled PID has a different
/// start time and misses the cache.
public actor SysctlProcessTable: ProcessTableSource {
  private struct Identity: Hashable {
    let pid: Int32
    let start: Date
  }

  private var cache: [Identity: (path: String, arguments: [String])] = [:]
  private let currentUID: UInt32

  public init(currentUID: UInt32 = getuid()) {
    self.currentUID = currentUID
  }

  public func snapshot() async -> [ProcessSnapshot] {
    let entries = Self.kernelProcesses(uid: currentUID)
    var fresh: [Identity: (path: String, arguments: [String])] = [:]
    var result: [ProcessSnapshot] = []
    result.reserveCapacity(entries.count)

    for entry in entries {
      let identity = Identity(pid: entry.pid, start: entry.start)
      let argv = cache[identity] ?? Self.arguments(pid: entry.pid) ?? (entry.name, [entry.name])
      fresh[identity] = argv
      result.append(
        ProcessSnapshot(
          pid: entry.pid, parentPID: entry.parentPID, ownerUID: entry.uid,
          startDate: entry.start, executablePath: argv.path, arguments: argv.arguments))
    }

    // Keeping only live identities bounds the cache to the process table.
    cache = fresh
    return result
  }

  private struct KernelEntry {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let start: Date
    let name: String
  }

  private static func kernelProcesses(uid: UInt32) -> [KernelEntry] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }

    // The table can grow between the size query and the read; leave headroom.
    let stride = MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = processes.count * stride
    guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }

    return processes.prefix(size / stride).compactMap { info in
      let pid = info.kp_proc.p_pid
      guard pid > 0 else { return nil }
      let started = info.kp_proc.p_un.__p_starttime
      let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      return KernelEntry(
        pid: pid,
        parentPID: info.kp_eproc.e_ppid,
        uid: info.kp_eproc.e_ucred.cr_uid,
        start: Date(
          timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000),
        name: name
      )
    }
  }

  /// Parses `KERN_PROCARGS2`: an `Int32` argc, the exec path, NUL padding, then argc
  /// NUL-terminated arguments (the environment follows and is ignored).
  static func arguments(pid: Int32) -> (path: String, arguments: [String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs(Array(buffer.prefix(size)))
  }

  public static func parseProcArgs(_ buffer: [UInt8]) -> (path: String, arguments: [String])? {
    let headerSize = MemoryLayout<Int32>.size
    guard buffer.count > headerSize else { return nil }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0 else { return nil }

    var cursor = headerSize
    func readString() -> String? {
      guard cursor < buffer.count else { return nil }
      let start = cursor
      while cursor < buffer.count, buffer[cursor] != 0 { cursor += 1 }
      let value = String(decoding: buffer[start..<cursor], as: UTF8.self)
      return value
    }

    guard let path = readString() else { return nil }
    while cursor < buffer.count, buffer[cursor] == 0 { cursor += 1 }

    var arguments: [String] = []
    while arguments.count < Int(argc), let argument = readString() {
      arguments.append(argument)
      cursor += 1
    }
    return (path, arguments)
  }
}
