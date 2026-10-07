import AppKit
import KDSCore

/// Drives the menu bar icon: samples CPU, picks a mood, and steps through its frames.
///
/// It runs whether or not the panel is open — the icon is the one place load is visible
/// at a glance. CPU is sampled every two seconds; the frame timer only runs at the tempo
/// of the current mood, and stops entirely under Reduce Motion.
@MainActor
final class MascotAnimator: ObservableObject {
  @Published private(set) var image: NSImage
  @Published private(set) var level: CPULoadLevel = .idle

  private let sampler = CPULoadSampler()
  private let frames: [CPULoadLevel: [NSImage]]
  private var frameIndex = 0
  private var frameTimer: Timer?
  private var sampleTask: Task<Void, Never>?
  private var reduceMotionObserver: NSObjectProtocol?

  init() {
    frames = MascotSprites.load()
    image = frames[.idle]?.first ?? MascotSprites.fallback

    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.restartFrameTimer() }
    }

    startSampling()
    restartFrameTimer()
  }

  private func startSampling() {
    sampleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let percent = await self.sampler.sample()
        self.apply(CPULoadLevel.level(for: percent, previous: self.level))
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          return
        }
      }
    }
  }

  private func apply(_ newLevel: CPULoadLevel) {
    guard newLevel != level else { return }
    level = newLevel
    frameIndex = 0
    showCurrentFrame()
    restartFrameTimer()
  }

  private func restartFrameTimer() {
    frameTimer?.invalidate()
    frameTimer = nil
    frameIndex = 0
    showCurrentFrame()

    // Reduce Motion keeps the mood — the drawing still changes with load — but holds
    // the first frame instead of animating.
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

    let timer = Timer(timeInterval: level.frameInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
    // `.common` keeps the icon moving while the panel's menu tracking runs the loop.
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  private func advance() {
    guard let count = frames[level]?.count, count > 0 else { return }
    frameIndex = (frameIndex + 1) % count
    showCurrentFrame()
  }

  private func showCurrentFrame() {
    guard let levelFrames = frames[level], !levelFrames.isEmpty else { return }
    image = levelFrames[frameIndex % levelFrames.count]
  }
}

enum MascotSprites {
  /// Point size of every frame; `Scripts/cut-sprites.swift` renders 1x and 2x to match.
  static let size = NSSize(width: 26, height: 22)

  static var fallback: NSImage {
    let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "KDS")!
    image.isTemplate = true
    return image
  }

  static func load() -> [CPULoadLevel: [NSImage]] {
    guard let directory = spritesDirectory() else { return [:] }
    var result: [CPULoadLevel: [NSImage]] = [:]
    for level in CPULoadLevel.allCases {
      let images = (0..<level.frameCount).compactMap { index in
        frame(named: "\(level.spriteName)-\(index)", in: directory)
      }
      if images.count == level.frameCount { result[level] = images }
    }
    return result
  }

  /// The packaged app carries the frames in `Contents/Resources/Sprites`; `swift run`
  /// finds them in the SwiftPM resource bundle. Checking the app first means the
  /// SwiftPM accessor, which traps when its bundle is absent, is never touched there.
  private static func spritesDirectory() -> URL? {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("Sprites"),
      FileManager.default.fileExists(atPath: url.path)
    {
      return url
    }
    return Bundle.module.resourceURL?.appendingPathComponent("Sprites")
  }

  /// One image, two representations, so the menu bar picks the sharp one per display.
  private static func frame(named name: String, in directory: URL) -> NSImage? {
    let image = NSImage(size: size)
    for suffix in ["", "@2x"] {
      let url = directory.appendingPathComponent("\(name)\(suffix).png")
      guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
        return nil
      }
      rep.size = size
      image.addRepresentation(rep)
    }
    // Template: the menu bar tints it for light, dark and tinted appearances.
    image.isTemplate = true
    image.accessibilityDescription = "KDS"
    return image
  }
}
