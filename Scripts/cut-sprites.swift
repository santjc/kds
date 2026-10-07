#!/usr/bin/env swift
// Cuts the presentation spritesheets for the menu bar mascot into template-ready frames.
//
//   swift Scripts/cut-sprites.swift <sheets-dir> <output-dir>
//
// Each sheet is a design board: a title, a caption, one row of frames, and a numeral
// under every frame. The cutter finds the heads (the large ink blobs), assigns every
// other ink blob between the caption and the numerals to its nearest head, and renders
// each frame onto a fixed canvas.
//
// Frames are normalised per state by face width (the bottom of the head), not by bounding
// box: the hotter states grow taller hair and fly droplets, and scaling those to fit would
// shrink the face and make the icon visibly jump between states. Within a state, every
// frame shares one anchor, so per-frame shake and bounce survive the cut.
//
// Output alpha is ink: black is opaque, white is clear. That is what a template image
// needs; the face reads as a cut-out and the menu bar tints the rest.

import AppKit

/// State name and the frame count printed on its board.
let states: [(name: String, frames: Int)] = [
  ("idle", 4), ("active", 4), ("busy", 6), ("hot", 6), ("very_hot", 8), ("critical", 8),
]

/// Canvas in points: the full 22pt menu bar height, so the mascot reads at a glance.
/// The room above the hair is for the droplets the hotter states throw.
let canvasWidth = 26.0
let canvasHeight = 22.0
let faceWidthPoints = 16.5
let faceBottomPoints = 20.6

struct Bitmap {
  let width: Int
  let height: Int
  var pixels: [UInt8]  // RGBA, premultiplied, top row first

  init(cgImage: CGImage) {
    width = cgImage.width
    height = cgImage.height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  /// 0 for clear or white, 1 for opaque black.
  func ink(_ x: Int, _ y: Int) -> Double {
    let index = (y * width + x) * 4
    let alpha = Double(pixels[index + 3]) / 255
    guard alpha > 0 else { return 0 }
    let luminance =
      (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2]))
      / 3 / 255 / alpha
    return alpha * min(1, max(0, (0.92 - luminance) / 0.8))
  }
}

struct Box {
  var minX: Int, minY: Int, maxX: Int, maxY: Int
  var width: Int { maxX - minX + 1 }
  var height: Int { maxY - minY + 1 }
  var midX: Double { Double(minX + maxX) / 2 }
  var midY: Double { Double(minY + maxY) / 2 }
}

struct Component {
  var box: Box
  var pixels: [Int]
}

func components(of bitmap: Bitmap, threshold: Double) -> [Component] {
  let count = bitmap.width * bitmap.height
  var seen = [Bool](repeating: false, count: count)
  var result: [Component] = []

  for start in 0..<count where !seen[start] {
    seen[start] = true
    guard bitmap.ink(start % bitmap.width, start / bitmap.width) > threshold else { continue }

    var stack = [start]
    var pixels: [Int] = []
    var box = Box(minX: .max, minY: .max, maxX: .min, maxY: .min)
    while let index = stack.popLast() {
      pixels.append(index)
      let x = index % bitmap.width
      let y = index / bitmap.width
      box.minX = min(box.minX, x)
      box.maxX = max(box.maxX, x)
      box.minY = min(box.minY, y)
      box.maxY = max(box.maxY, y)
      for dy in -1...1 {
        for dx in -1...1 {
          let nx = x + dx
          let ny = y + dy
          guard nx >= 0, ny >= 0, nx < bitmap.width, ny < bitmap.height else { continue }
          let neighbour = ny * bitmap.width + nx
          guard !seen[neighbour] else { continue }
          seen[neighbour] = true
          if bitmap.ink(nx, ny) > threshold { stack.append(neighbour) }
        }
      }
    }
    result.append(Component(box: box, pixels: pixels))
  }
  return result
}

func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  return sorted[sorted.count / 2]
}

/// Width of the head across its lower third: the face, which every state draws the same.
func faceWidth(of head: Component, in bitmap: Bitmap) -> Double {
  let floorY = head.box.maxY - head.box.height / 3
  var widest = 0
  var rows: [Int: (Int, Int)] = [:]
  for index in head.pixels {
    let x = index % bitmap.width
    let y = index / bitmap.width
    guard y >= floorY else { continue }
    let row = rows[y] ?? (x, x)
    rows[y] = (min(row.0, x), max(row.1, x))
  }
  for (_, span) in rows { widest = max(widest, span.1 - span.0 + 1) }
  return Double(widest)
}

func png(from context: CGContext) -> Data {
  let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
  return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  print("usage: cut-sprites.swift <sheets-dir> <output-dir>")
  exit(1)
}
let sheetsDirectory = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sheetFiles = FileManager.default.enumerator(at: sheetsDirectory, includingPropertiesForKeys: nil)!
  .compactMap { $0 as? URL }
  .filter { $0.pathExtension == "png" }

for (state, frameCount) in states {
  guard let file = sheetFiles.first(where: { $0.lastPathComponent == "lomi_cpu_\(state)_spritesheet.png" })
  else {
    print("✗ \(state): no sheet")
    exit(1)
  }
  let image = NSImage(contentsOf: file)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
  let bitmap = Bitmap(cgImage: image)
  // A blob touching the right edge is a sliver of the neighbouring board.
  let blobs = components(of: bitmap, threshold: 0.06).filter { $0.box.maxX < bitmap.width - 2 }

  let heads = Array(blobs.sorted { $0.pixels.count > $1.pixels.count }.prefix(frameCount))
    .sorted { $0.box.minX < $1.box.minX }
  let headHeight = median(heads.map { Double($0.box.height) })
  let headTop = median(heads.map { Double($0.box.minY) })
  let headBottom = median(heads.map { Double($0.box.maxY) })

  // Caption text sits well above the hair; numerals sit well below the chin. Droplets
  // and motion marks live in between.
  let bandTop = headTop - headHeight * 0.5
  let bandBottom = headBottom + headHeight * 0.2
  var frames = heads.map { [$0] }
  for blob in blobs where !heads.contains(where: { $0.pixels.first == blob.pixels.first }) {
    guard blob.box.midY > bandTop, blob.box.midY < bandBottom else { continue }
    // The hairline dividing one board from the next is tall and a few pixels wide.
    guard !(blob.box.height > Int(headHeight / 2) && blob.box.width < 8) else { continue }
    let nearest = heads.indices.min { abs(heads[$0].box.midX - blob.box.midX) < abs(heads[$1].box.midX - blob.box.midX) }!
    frames[nearest].append(blob)
  }

  let scale = faceWidthPoints / median(heads.map { faceWidth(of: $0, in: bitmap) })
  let anchorBottom = headBottom

  // Frames sit on a regular grid; a head's offset from its slot is the animation's shake,
  // so anchor each frame to its fitted slot, not to its own head.
  let centres = heads.map(\.box.midX)
  let meanIndex = Double(centres.count - 1) / 2
  let meanCentre = centres.reduce(0, +) / Double(centres.count)
  var covariance = 0.0
  var variance = 0.0
  for (index, centre) in centres.enumerated() {
    let offset = Double(index) - meanIndex
    covariance += offset * (centre - meanCentre)
    variance += offset * offset
  }
  let pitch = covariance / variance

  for (frameIndex, parts) in frames.enumerated() {
    let anchorX = meanCentre + (Double(frameIndex) - meanIndex) * pitch

    // The frame's ink as a black image whose alpha is the ink, sized to the whole sheet so
    // source coordinates map straight through one transform.
    var buffer = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
    for part in parts {
      // Pad each blob by its anti-aliased fringe, which falls below the threshold.
      let pad = 2
      for y in max(0, part.box.minY - pad)...min(bitmap.height - 1, part.box.maxY + pad) {
        for x in max(0, part.box.minX - pad)...min(bitmap.width - 1, part.box.maxX + pad) {
          let alpha = UInt8((bitmap.ink(x, y) * 255).rounded())
          buffer[(y * bitmap.width + x) * 4 + 3] = max(buffer[(y * bitmap.width + x) * 4 + 3], alpha)
        }
      }
    }
    let inkImage = buffer.withUnsafeMutableBytes { bytes in
      CGContext(
        data: bytes.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
        bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    for multiplier in [1, 2] {
      let pixelWidth = Int(canvasWidth) * multiplier
      let pixelHeight = Int(canvasHeight) * multiplier
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.interpolationQuality = .high

      let pixelsPerSource = scale * Double(multiplier)
      // CoreGraphics is bottom-up; the sheet maths above is top-down.
      let originX = Double(pixelWidth) / 2 - anchorX * pixelsPerSource
      let originYFromTop = faceBottomPoints * Double(multiplier) - (anchorBottom + 1) * pixelsPerSource
      let drawnHeight = Double(bitmap.height) * pixelsPerSource
      context.draw(
        inkImage,
        in: CGRect(
          x: originX, y: Double(pixelHeight) - originYFromTop - drawnHeight,
          width: Double(bitmap.width) * pixelsPerSource, height: drawnHeight))

      let suffix = multiplier == 1 ? "" : "@\(multiplier)x"
      let name = "\(state)-\(frameIndex)\(suffix).png"
      try png(from: context).write(to: outputDirectory.appendingPathComponent(name))
    }
  }
  print("✓ \(state): \(frames.count) frames, \(frames.map(\.count).reduce(0, +) - frames.count) satellite blobs")
}
