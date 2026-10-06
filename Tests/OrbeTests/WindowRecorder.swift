import AppKit
import CoreMedia
import ScreenCaptureKit
import os

/// 窓が画面に出したコマを受け（ScreenCaptureKit）、コマごとに区画の枠線の行と上下の印の行の距離を引き、PNG に書き出す。
/// 枠線は `strokeX` の列で紫の画素の行（試しのスレッドの枠線 tint(accent, 0.35)）、印の行は `markerX` の列で明るい画素の行。
final class WindowRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
  struct Report {
    var frames = 0
    var above: [Int] = []
    var below: [Int] = []
    var sheet: URL?

    func range(_ values: [Int]) -> String {
      guard let low = values.min(), let high = values.max() else { return "-" }
      return "\(low)...\(high)"
    }
  }

  private let strokeX: Int
  private let markerX: Int
  private let top: Int
  private let output: URL
  private let state = OSAllocatedUnfairLock(initialState: Report())
  private let writer = DispatchQueue(label: "rows-trial.png")
  private var thumbnails: [CGImage] = []
  private var stream: SCStream?

  init(strokeX: Int, markerX: Int, top: Int, output: URL) {
    self.strokeX = strokeX
    self.markerX = markerX
    self.top = top
    self.output = output
  }

  @MainActor
  func start(_ window: NSWindow) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
    else { throw CocoaError(.featureUnsupported) }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let configuration = SCStreamConfiguration()
    let scale = window.backingScaleFactor
    configuration.width = Int(window.frame.width * scale)
    configuration.height = Int(window.frame.height * scale)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.queueDepth = 8
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(
      self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rows-trial"))
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() async {
    try? await stream?.stopCapture()
    stream = nil
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen, Self.isComplete(buffer), let pixels = buffer.imageBuffer else { return }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let frame = FrameBytes(pixels) else { return }
    let gaps = measure(frame)
    let count = state.withLock { report -> Int in
      report.frames += 1
      report.above += gaps.above
      report.below += gaps.below
      return report.frames
    }
    guard let image = frame.image() else { return }
    let url = output.appendingPathComponent(String(format: "frame_%03d.png", count))
    writer.async { [weak self] in
      Self.write(image, to: url)
      if count % 6 == 1 { self?.thumbnails.append(image) }
    }
  }

  private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int
    else { return false }
    return status == SCFrameStatus.complete.rawValue
  }

  /// コマ 1 枚の、区画ごとの枠線と上下の印の行の距離（画素）。枠線の行は上から組にして、上端と下端とみる。
  private func measure(_ frame: FrameBytes) -> (above: [Int], below: [Int]) {
    let purple = { (y: Int) -> Bool in
      let c = frame.rgb(self.strokeX, y)
      return c.b - c.g > 35 && c.b > 70
    }
    let bright = { (y: Int) -> Bool in
      let c = frame.rgb(self.markerX, y)
      return c.r + c.g + c.b > 3 * 150
    }
    var strokes: [ClosedRange<Int>] = []
    var y = top
    while y < frame.height {
      if purple(y) {
        let start = y
        while y + 1 < frame.height, purple(y + 1) { y += 1 }
        strokes.append(start...y)
      }
      y += 1
    }
    var above: [Int] = []
    var below: [Int] = []
    for pair in stride(from: 0, to: strokes.count - 1, by: 2) {
      let first = strokes[pair].lowerBound
      let last = strokes[pair + 1].upperBound
      var a = first - 1
      while a > top, !bright(a) { a -= 1 }
      var c = last + 1
      while c < frame.height - 1, !bright(c) { c += 1 }
      guard a > top, c < frame.height - 1 else { continue }
      above.append(first - a)
      below.append(c - last)
    }
    return (above, below)
  }

  /// 受け終えた——書き出しを待ち、並べた 1 枚（6 コマおき）を書いて、引いた距離を返す。
  func finish() -> Report {
    writer.sync {}
    var report = state.withLock { $0 }
    let shots = Array(thumbnails.prefix(24))
    guard let first = shots.first else { return report }
    let cell = (width: first.width / 4, height: first.height / 4)
    let columns = 8
    let rows = (shots.count + columns - 1) / columns
    guard
      let context = CGContext(
        data: nil, width: cell.width * columns, height: cell.height * rows, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return report }
    for (index, shot) in shots.enumerated() {
      let x = (index % columns) * cell.width
      let y = (rows - 1 - index / columns) * cell.height
      context.draw(shot, in: CGRect(x: x, y: y, width: cell.width, height: cell.height))
    }
    let url = output.appendingPathComponent("sheet.png")
    if let sheet = context.makeImage() {
      Self.write(sheet, to: url)
      report.sheet = url
    }
    return report
  }

  private static func write(_ image: CGImage, to url: URL) {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }
}

/// 受けたコマの画素（BGRA）。
private struct FrameBytes {
  struct RGB {
    var r: Int
    var g: Int
    var b: Int
  }

  let bytes: UnsafePointer<UInt8>
  let width: Int
  let height: Int
  let row: Int

  init?(_ pixels: CVPixelBuffer) {
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
    bytes = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
    width = CVPixelBufferGetWidth(pixels)
    height = CVPixelBufferGetHeight(pixels)
    row = CVPixelBufferGetBytesPerRow(pixels)
  }

  func rgb(_ x: Int, _ y: Int) -> RGB {
    let p = bytes + y * row + x * 4
    return RGB(r: Int(p[2]), g: Int(p[1]), b: Int(p[0]))
  }

  /// 画素を写した絵。
  func image() -> CGImage? {
    let data = Data(bytes: bytes, count: row * height)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
