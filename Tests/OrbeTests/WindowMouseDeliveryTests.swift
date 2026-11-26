import AppKit
import SwiftUI
import XCTest

/// マウスを届けるテスト支援（`deliverClick`）が、押下で追跡ループに入りうる部品（入力欄、選べる文字）を押しても戻り、
/// 押した部品に焦点を移し、離すイベントをキューに残さないこと。
///
/// 壊れると何が起きるか。入力欄や選べる文字を押すテストが、押下の配送の中で離すイベントを待ち続け、テストの実行が止まる。
/// 手元の macOS 27 では、テストの条件（窓は key でなく、アプリは前面でない）で押下を送っても追跡ループに入らないので、手元で
/// 通っても、追跡ループに入る環境で戻ることまでは確かめられない。
/// 離すイベントがキューに残ると、後のテストの配送に紛れ込む。
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
