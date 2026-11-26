import AppKit
import XCTest

@testable import Orbe

/// 行の高さを決めたメッセージ欄（`MessageTextView.Metrics.lineHeight`）の高さと、esc の知らせ。ポップアップの入力欄（コミット・
/// レビュー）が使う。esc の知らせを持たない欄は、esc の命令を取らず、例外も出さずに、次の responder（最後は窓）へ渡す。
///
/// 壊れると何が起きるか: ポップアップの入力欄が、行を足すたびに、決めた行の高さと違う高さで伸びる。字の高い行（タイ文字）や、
/// 打った行・書きかけを入れ直した行の一方だけ高さが変わり、欄が揺れる。⇧↵ の直後だけ欄が縮む。10 行を越えても伸び続け、
/// ポップアップの下に並ぶ失敗の札を押し出す。esc でポップアップが閉じない。変換を取り消す esc で、ポップアップまで閉じる。
/// esc の知らせを持たない欄で esc を押すと例外が出る。esc の命令が欄で止まり、上の responder が esc を受けない。
@MainActor
final class MessageTextViewTests: OrbeTestCase {
  /// 行の高さ 20・1 行のときの欄の高さ 30。
  private func field() -> MessageTextView {
    MessageTextView(
      metrics: .init(
        font: .systemFont(ofSize: 12.5), height: 30, lineHeight: 20, leading: 0, trailing: 0))
  }

  private func height(_ field: MessageTextView) -> CGFloat {
    field.fittingHeight(width: 300, maxLines: 10)
  }

  /// 空で 30、行ごとに 20 ずつ伸び、10 行で止まる。中身を入れ直した行（`string`）でも、打った行（`insertText`）でも、字の
  /// 高い行でも、伸び方は同じ。
  func testAFieldWithALineHeightGrowsByThatHeightPerLineUpToTenLines() {
    let field = field()
    XCTAssertEqual(height(field), 30, accuracy: 0.5, "空")

    field.string = ["a", "b", "c"].joined(separator: "\n")
    XCTAssertEqual(height(field), 70, accuracy: 0.5, "3 行")
    field.string = Array(repeating: "ปั้ญู", count: 3).joined(separator: "\n")
    XCTAssertEqual(height(field), 70, accuracy: 0.5, "字の高い 3 行")
    field.frame.size.width = 300
    field.sizeToFit()
    XCTAssertEqual(field.frame.height, 70, accuracy: 0.5, "字の高い 3 行を表示したときの高さも、測った高さと同じ")
    field.string = Array(repeating: "a", count: 12).joined(separator: "\n")
    XCTAssertEqual(height(field), 210, accuracy: 0.5, "10 行で止まる")

    field.string = ""
    field.insertText("a\nb\nc", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(height(field), 70, accuracy: 0.5, "打った 3 行")
  }

  /// 末尾の改行の後の、字の無い行も、決めた行の高さ。
  func testTheEmptyLineAfterATrailingNewlineHasTheLineHeight() {
    let set = field()
    set.string = "a\n"
    XCTAssertEqual(height(set), 50, accuracy: 0.5, "入れ直した、末尾の改行の後の行")

    let typed = field()
    typed.insertText("a\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(height(typed), 50, accuracy: 0.5, "打った、末尾の改行の後の行")

    let replaced = field()
    replaced.string = "ปั้ญู"
    replaced.string = "a\n"
    XCTAssertEqual(height(replaced), 50, accuracy: 0.5, "字の高い文字列を入れた後に入れ直した、末尾の改行の後の行")
    replaced.frame.size.width = 300
    replaced.sizeToFit()
    XCTAssertEqual(replaced.frame.height, 50, accuracy: 0.5, "表示したときの高さも、測った高さと同じ")
  }

  /// esc の知らせを持つ欄では、変換中でない esc の命令が知らせを呼ぶ。変換中の esc の命令では呼ばない。
  func testEscapeIsReportedOnlyWhileNotComposing() {
    let field = field()
    var escapes = 0
    field.onEscape = { escapes += 1 }
    let escape = #selector(NSResponder.cancelOperation(_:))

    field.doCommand(by: escape)
    XCTAssertEqual(escapes, 1, "変換中でなければ呼ぶ")

    field.setMarkedText(
      "かん", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(field.hasMarkedText(), "前提: 変換中")
    field.doCommand(by: escape)
    XCTAssertEqual(escapes, 1, "変換中は呼ばない")
  }

  /// esc の命令が届いた回数を数える窓。
  private final class EscapeCountingWindow: NSWindow {
    var escapes = 0

    override func cancelOperation(_ sender: Any?) { escapes += 1 }
  }

  /// esc の知らせを持たない欄で esc を押すと、esc の命令は窓まで渡る。欄のフォーカスと打った文は残る。
  func testEscapeInAFieldWithoutTheReportGoesOnToTheWindow() throws {
    let window = EscapeCountingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    let field = field()
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
    window.contentView?.addSubview(field)
    holdUntilTestEnds(window)
    window.makeFirstResponder(field)
    field.insertText("fix", replacementRange: NSRange(location: NSNotFound, length: 0))

    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53))
    deliverKeyDown(escape, to: window)
    XCTAssertEqual(window.escapes, 1, "esc の命令は窓まで渡る")
    XCTAssertTrue(window.firstResponder === field, "フォーカスは欄に残る")
    XCTAssertEqual(field.string, "fix", "打った文は残る")
  }
}
