import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 編集できる面のテストの足場。面の view を窓に載せる（画面には出さない・前面を取らない）と、焦点・キー・マウスの出来事が
/// 本物の経路で届く。
@MainActor
extension EngineTestCase {
  /// 面を載せた窓（出さない）。view を first responder にする。
  func host(_ opened: Opened, size: CGSize = CGSize(width: 800, height: 600)) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = opened.surface.view
    window.makeFirstResponder(opened.surface.responder)
    opened.surface.viewStateDidChange(size: size, scale: 2, visible: false)
    addTeardownBlock { @MainActor in window.contentView = nil }
    return window
  }

  /// 打鍵（macOS のキー割り当てを通る）。`characters` は字、または矢印などの機能キーの字（`NSUpArrowFunctionKey` など）。
  func key(
    _ opened: Opened, _ characters: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
  ) throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: CACurrentMediaTime(),
        windowNumber: opened.surface.view.window?.windowNumber ?? 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: keyCode))
    opened.surface.responder.keyDown(with: event)
  }

  /// 字を 1 つずつ打つ。
  func type(_ opened: Opened, _ string: String) {
    for character in string { opened.surface.responder.insertText(String(character)) }
  }

  /// マウスの出来事を view の点（flipped、pt）へ送る。
  func mouse(
    _ opened: Opened, _ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
    flags: NSEvent.ModifierFlags = []
  ) throws {
    let view = opened.surface.view
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: flags,
        timestamp: CACurrentMediaTime(), windowNumber: view.window?.windowNumber ?? 0,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    switch type {
    case .leftMouseDown: view.mouseDown(with: event)
    case .leftMouseDragged: view.mouseDragged(with: event)
    default: view.mouseUp(with: event)
    }
  }

  /// 行・桁（半角）の点（view の座標）。先頭の行が見えている前提。
  func point(_ opened: Opened, row: Int, column: CGFloat) -> CGPoint {
    let config = opened.surface.config
    let text = opened.document.text
    return CGPoint(
      x: config.columnWidth(lineCount: text.lineCount) + (column + 0.3) * config.cell,
      y: config.topInset + (CGFloat(row) + 0.5) * config.lineHeight)
  }

  /// 行 `row` の位置 `offset`（行頭から）のキャレットの x（pt。行頭から）——面と同じ組版の規則で組んだ行から。
  func caretX(_ opened: Opened, row: Int, offset: Int) -> CGFloat {
    let config = opened.surface.config
    let source = LineShaper.source(row: row, in: opened.document.text).source
    let tab = config.tabWidth(columns: opened.document.indentation.unit)
    return LineShaper.shape(source, font: config.font, tabWidth: tab).carets.x(offset)
  }

  func click(
    _ opened: Opened, row: Int, column: CGFloat, clicks: Int = 1, flags: NSEvent.ModifierFlags = []
  )
    throws
  {
    let at = point(opened, row: row, column: column)
    try mouse(opened, .leftMouseDown, at: at, clicks: clicks, flags: flags)
    try mouse(opened, .leftMouseUp, at: at, clicks: clicks, flags: flags)
  }

  func text(_ document: EditorDocument) -> String {
    document.text.substring(NSRange(location: 0, length: document.text.length))
  }

  /// 画像の 1 画素（px。sRGB の 0…255 の [r, g, b, a]、α 乗算済み）。
  func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(
      image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return bytes.map(Int.init)
  }
}
