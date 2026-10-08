#!/usr/bin/env swift
// Cuts the menu bar mascot's spritesheets into template-ready frames.
//
//   swift Scripts/cut-sprites.swift <sheets-dir> <output-dir>
//
// Each sheet `lomi_<state>.png` is an evenly spaced grid of frames, read row by row.
//
// Every frame is anchored on its own eyes: the sheets are not laid out on an exact grid,
// so anchoring on the cell would turn layout slop into a jitter nobody drew. The
// animation lives in the hair, which moves around the fixed eyes.
//
// Each state then fills the canvas: the union of its frames' ink, measured around the
// eyes, is scaled to the largest size that fits and centred. Frames within a state share
// that scale and position, so the animation never wobbles in size.
//
// Output alpha is ink: black is opaque, white and transparent are clear. That is what a
// template image needs; the face reads as a cut-out and the menu bar tints the rest.

import AppKit

/// State name, then its grid as columns × rows.
let states: [(name: String, columns: Int, rows: Int)] = [
  ("idle", 2, 2), ("active", 2, 2), ("busy", 3, 2), ("hot", 3, 2), ("very_hot", 4, 2),
  ("critical", 4, 2),
]

/// Canvas in points: the full 22pt menu bar height, so the mascot reads at a glance.
let canvasWidth = 24.0
let canvasHeight = 22.0
/// Breathing room kept clear at every edge.
let margin = 0.25

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
  var midX: Double { Double(minX + maxX) / 2 }
  var midY: Double { Double(minY + maxY) / 2 }
}

struct Component {
  var box: Box
  var area: Int
}

func components(of bitmap: Bitmap, threshold: Double) -> [Component] {
  let count = bitmap.width * bitmap.height
  var seen = [Bool](repeating: false, count: count)
  var result: [Component] = []

  for start in 0..<count where !seen[start] {
    seen[start] = true
    guard bitmap.ink(start % bitmap.width, start / bitmap.width) > threshold else { continue }

    var stack = [start]
    var area = 0
    var box = Box(minX: .max, minY: .max, maxX: .min, maxY: .min)
    while let index = stack.popLast() {
      area += 1
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
    result.append(Component(box: box, area: area))
  }
  return result
}

/// One frame as measured on its sheet, in sheet pixels.
struct Frame {
  let cell: CGRect
  /// Every ink blob in the cell, unioned.
  let ink: Box
  let eyeCentre: CGPoint
}

struct Sheet {
  let name: String
  let bitmap: Bitmap
  let frames: [Frame]
}

func measure(name: String, columns: Int, rows: Int, file: URL) -> Sheet {
  let image = NSImage(contentsOf: file)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
  let bitmap = Bitmap(cgImage: image)
  let blobs = components(of: bitmap, threshold: 0.5).filter { $0.area > 12 }
  let cellWidth = Double(bitmap.width) / Double(columns)
  let cellHeight = Double(bitmap.height) / Double(rows)

  var frames: [Frame] = []
  for row in 0..<rows {
    for column in 0..<columns {
      let cell = CGRect(
        x: Double(column) * cellWidth, y: Double(row) * cellHeight, width: cellWidth,
        height: cellHeight)
      let inCell = blobs.filter { cell.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        .sorted { $0.area > $1.area }
      guard let hair = inCell.first else {
        print("✗ \(name) frame \(frames.count): empty cell")
        exit(1)
      }
      // The eyes are the two largest blobs below the middle of the hair.
      let eyes = inCell.dropFirst().filter { $0.box.midY > hair.box.midY }.prefix(2)
      guard eyes.count == 2 else {
        print("✗ \(name) frame \(frames.count): could not find both eyes")
        exit(1)
      }
      let left = eyes.min { $0.box.midX < $1.box.midX }!
      let right = eyes.max { $0.box.midX < $1.box.midX }!
      let ink = inCell.dropFirst().reduce(hair.box) { union, blob in
        Box(
          minX: min(union.minX, blob.box.minX), minY: min(union.minY, blob.box.minY),
          maxX: max(union.maxX, blob.box.maxX), maxY: max(union.maxY, blob.box.maxY))
      }
      frames.append(
        Frame(
          cell: cell,
          ink: ink,
          eyeCentre: CGPoint(
            x: (left.box.midX + right.box.midX) / 2, y: (left.box.midY + right.box.midY) / 2)
        ))
    }
  }

  return Sheet(name: name, bitmap: bitmap, frames: frames)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  print("usage: cut-sprites.swift <sheets-dir> <output-dir>")
  exit(1)
}
let sheetsDirectory = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sheets = states.map { state -> Sheet in
  let file = sheetsDirectory.appendingPathComponent("lomi_\(state.name).png")
  guard FileManager.default.fileExists(atPath: file.path) else {
    print("✗ \(state.name): no sheet at \(file.path)")
    exit(1)
  }
  return measure(name: state.name, columns: state.columns, rows: state.rows, file: file)
}

/// Where a state's frames land: its ink, measured around each frame's eyes and unioned
/// over all frames, scaled to fit the canvas and centred in it.
struct Placement {
  let pixelsPerSource: Double  // canvas points per sheet pixel
  let eyeX: Double  // eye centre in canvas points, from the left
  let eyeY: Double  // eye centre in canvas points, from the top
}

func placement(for sheet: Sheet) -> Placement {
  var left = 0.0
  var right = 0.0
  var up = 0.0
  var down = 0.0
  for frame in sheet.frames {
    let eye = frame.eyeCentre
    left = max(left, eye.x - Double(frame.ink.minX))
    right = max(right, Double(frame.ink.maxX + 1) - eye.x)
    up = max(up, eye.y - Double(frame.ink.minY))
    down = max(down, Double(frame.ink.maxY + 1) - eye.y)
  }
  let scale = min(
    (canvasWidth - 2 * margin) / (left + right), (canvasHeight - 2 * margin) / (up + down))
  return Placement(
    pixelsPerSource: scale,
    eyeX: (canvasWidth - (left + right) * scale) / 2 + left * scale,
    eyeY: (canvasHeight - (up + down) * scale) / 2 + up * scale)
}

for sheet in sheets {
  for (index, frame) in sheet.frames.enumerated() {
    // Only this cell's pixels, so a neighbour's sparks never bleed in.
    let cell = frame.cell.integral
    var buffer = [UInt8](repeating: 0, count: Int(cell.width) * Int(cell.height) * 4)
    for y in Int(cell.minY)..<min(Int(cell.maxY), sheet.bitmap.height) {
      for x in Int(cell.minX)..<min(Int(cell.maxX), sheet.bitmap.width) {
        let local = ((y - Int(cell.minY)) * Int(cell.width) + (x - Int(cell.minX))) * 4
        buffer[local + 3] = UInt8((sheet.bitmap.ink(x, y) * 255).rounded())
      }
    }
    let inkImage = buffer.withUnsafeMutableBytes { bytes in
      CGContext(
        data: bytes.baseAddress, width: Int(cell.width), height: Int(cell.height),
        bitsPerComponent: 8, bytesPerRow: Int(cell.width) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    let origin = frame.eyeCentre
    let place = placement(for: sheet)
    for multiplier in [1, 2] {
      let pixelWidth = Int(canvasWidth) * multiplier
      let pixelHeight = Int(canvasHeight) * multiplier
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.interpolationQuality = .high

      let pixelsPerSource = place.pixelsPerSource * Double(multiplier)
      let left = place.eyeX * Double(multiplier) - (origin.x - cell.minX) * pixelsPerSource
      let top = place.eyeY * Double(multiplier) - (origin.y - cell.minY) * pixelsPerSource
      let drawnHeight = cell.height * pixelsPerSource
      // CoreGraphics is bottom-up; the sheet maths above is top-down.
      context.draw(
        inkImage,
        in: CGRect(
          x: left, y: Double(pixelHeight) - top - drawnHeight,
          width: cell.width * pixelsPerSource, height: drawnHeight))

      let suffix = multiplier == 1 ? "" : "@\(multiplier)x"
      let data = NSBitmapImageRep(cgImage: context.makeImage()!)
        .representation(using: .png, properties: [:])!
      try data.write(to: outputDirectory.appendingPathComponent("\(sheet.name)-\(index)\(suffix).png"))
    }
  }
  print("✓ \(sheet.name): \(sheet.frames.count) frames")
}
