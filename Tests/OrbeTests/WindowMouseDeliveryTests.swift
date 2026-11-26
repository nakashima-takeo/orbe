import AppKit
import SwiftUI
import XCTest

/// マウスを届けるテスト支援（`deliverClick`）が、押下で追跡ループに入りうる部品（入力欄、選べる文字）を押しても戻り、
/// 押した部品に焦点を移し、離すイベントをキューに残さないこと。追跡ループに入らない部品には、離すイベントを押した点で
/// 届けること。
///
/// 壊れると何が起きるか。入力欄や選べる文字を押すテストが、押下の配送の中で離すイベントを待ち続け、テストの実行が止まる。
/// 離すイベントが押した点から外れて届くと、SwiftUI のタップが成り立たず、クリックで動くはずの部品を押すテストが落ちる。
/// 離すイベントがキューに残ると、後のテストの配送に紛れ込む。テストの条件（窓は key でなく、アプリは前面でない）で押下が
/// 追跡ループに入るのは macOS 26 で、macOS 27 では入らないので、手元の macOS 27 で通っても、追跡ループに入る場合に戻る
/// ことは確かめられない。
final class WindowMouseDeliveryTests: OrbeTestCase {
  /// 中身を、タイトルバーの無い窓に載せ、画面外へ並べる。
  private func shown(_ content: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    holdUntilTestEnds(window)
    placeOffscreen(window)
    flush(window)
    return window
  }

  private func assertNoReleaseLeft(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(
      NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true),
      "離すイベントがキューに残らない", file: file, line: line)
  }

  /// 入力欄を押すと戻り、その入力欄が編集を受ける。
  func testClickingATextFieldReturnsAndEditsIt() {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
    let pressed = NSTextField(string: "押す入力欄")
    pressed.frame = NSRect(x: 20, y: 44, width: 200, height: 24)
    let other = NSTextField(string: "別の入力欄")
    other.frame = NSRect(x: 20, y: 12, width: 200, height: 24)
    content.addSubview(pressed)
    content.addSubview(other)
    let window = shown(content)
    window.makeFirstResponder(other)
    XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === other, "前提: 別の入力欄が編集を受けている")

    deliverClick(at: NSPoint(x: pressed.frame.midX, y: pressed.frame.midY), in: window)

    XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === pressed, "押した入力欄が編集を受ける")
    assertNoReleaseLeft()
  }

  /// 追跡ループに入らない部品を押すと、押下と離すイベントが 1 回ずつ、押した点で届く。
  func testClickingAPlainViewDeliversTheReleaseAtThePressedPoint() {
    final class Recorder: NSView {
      var downs: [NSPoint] = []
      var ups: [NSPoint] = []
      override func mouseDown(with event: NSEvent) { downs.append(event.locationInWindow) }
      override func mouseUp(with event: NSEvent) { ups.append(event.locationInWindow) }
    }
    let recorder = Recorder(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
    let window = OrbeWindowFake(
      contentRect: recorder.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = recorder
    holdUntilTestEnds(window)
    placeOffscreen(window)
    let point = NSPoint(x: 150, y: 30)

    deliverClick(at: point, in: window)

    XCTAssertEqual(recorder.downs, [point], "押下が押した点で 1 回届く")
    XCTAssertEqual(recorder.ups, [point], "離すイベントが押した点で 1 回届く")
    assertNoReleaseLeft()
  }

  /// 選べる文字（`.textSelection(.enabled)`）を押すと戻り、焦点がその文字へ移る。
  func testClickingSelectableTextReturnsAndFocusesIt() {
    let host = NSHostingView(
      rootView: Text("選べる文字").textSelection(.enabled).frame(width: 300, height: 40))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
    let window = shown(host)
    let inHost = { (window.firstResponder as? NSView)?.isDescendant(of: host) == true }
    XCTAssertFalse(inHost(), "前提: 焦点は文字に無い")

    deliverClick(at: NSPoint(x: host.bounds.midX, y: host.bounds.midY), in: window)

    XCTAssertTrue(inHost(), "押した文字が焦点を取る")
    assertNoReleaseLeft()
  }
}
