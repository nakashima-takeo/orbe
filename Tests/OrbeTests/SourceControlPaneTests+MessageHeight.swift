import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミットのポップアップのメッセージ欄の高さ——中身の行に合わせて伸び縮みし、10 行で止まってその先は中でスクロールする。
/// 1 行が高い文字でも 10 行分の高さまで伸びる。
///
/// 壊れると何が起きるか。改行しても欄が伸びず、打った行が見えない。10 行を越えるとキャレットの行が見えない・スクロールバーが
/// 字の幅を狭めて折り返しが変わる。タイ文字の欄が 10 行分の手前で止まる。
extension SourceControlPaneTests {
  /// 欄は中身の行に合わせてその場で伸び縮みする——打鍵の改行で 1 行ずつ伸び、外からの差し替えでも中身に合い、空にすれば
  /// 1 行の 30 に戻る。折り返す文は、窓を狭める・広げる・戻すのどれでも（ポップアップの幅が窓に合わせて変わる）、その幅で
  /// 組んだ行の高さに合う。
  func testTheMessageGrowsAndShrinksWithItsLines() throws {
    let hosted = host(try TempGitRepo())
    let field = try type("a", in: hosted)
    let scroll = try XCTUnwrap(field.enclosingScrollView)
    func height() -> CGFloat {
      hosted.pane.layoutSubtreeIfNeeded()
      return scroll.frame.height
    }
    XCTAssertEqual(height(), Theme.Layout.editorCommitMessage, accuracy: 0.5, "1 行")
    let line = Theme.Layout.editorCommitMessageLine

    field.keyDown(with: .key("\r", [.shift]))
    pumpMain(until: { height() > Theme.Layout.editorCommitMessage }, "改行で伸びる")
    XCTAssertEqual(height(), Theme.Layout.editorCommitMessage + line, accuracy: 0.5, "2 行")

    hosted.scm.control.message = "x\ny\nz"
    pumpMain(until: { field.string == "x\ny\nz" }, "外の差し替えが欄に届く")
    XCTAssertEqual(height(), Theme.Layout.editorCommitMessage + line * 2, accuracy: 0.5, "3 行")

    hosted.scm.control.message = ""
    pumpMain(until: { field.string.isEmpty }, "空にする")
    XCTAssertEqual(height(), Theme.Layout.editorCommitMessage, accuracy: 0.5, "1 行に戻る")

    let wrapping = String(repeating: "word ", count: 30)
    hosted.scm.control.message = wrapping
    pumpMain(until: { field.string == wrapping }, "折り返す文")
    func wrappedHeight() -> CGFloat {
      let layout = field.layoutManager!
      layout.ensureLayout(for: field.textContainer!)
      return layout.usedRect(for: field.textContainer!).height + Theme.Layout.editorCommitMessage
        - line
    }
    var heights: [CGFloat] = []
    for width in [300, 520, 400] as [CGFloat] {
      hosted.window.setContentSize(NSSize(width: width, height: 400))
      pumpMain(until: { abs(height() - wrappedHeight()) < 0.5 }, "幅 \(width) の行に合う")
      heights.append(height())
    }
    XCTAssertEqual(Set(heights).count, 3, "前提: 幅ごとに行の数が違う \(heights)")
  }

  /// 欄は 10 行で止まり、その先は中がスクロールして、打った行とキャレットが見えるように送られる。スクロールバーは字の幅を
  /// 狭めない。
  func testTheMessageScrollsPastTenLinesKeepingTheCaretInView() throws {
    let hosted = host(try TempGitRepo())
    let field = try type("a", in: hosted)
    let scroll = try XCTUnwrap(field.enclosingScrollView)
    let line = Theme.Layout.editorCommitMessageLine
    let tallest = Theme.Layout.editorCommitMessage + line * CGFloat(ScmMessageField.maxLines - 1)
    for lines in 2...13 {
      field.keyDown(with: .key("\r", [.shift]))
      let height = min(Theme.Layout.editorCommitMessage + line * CGFloat(lines - 1), tallest)
      pumpMain(
        until: {
          hosted.pane.layoutSubtreeIfNeeded()
          return abs(scroll.frame.height - height) < 0.5
        }, "\(lines) 行の高さ")
      let caret = field.layoutManager!.extraLineFragmentRect.offsetBy(
        dx: field.textContainerOrigin.x, dy: field.textContainerOrigin.y)
      XCTAssertTrue(field.visibleRect.contains(caret), "\(lines) 行: キャレットの行が見える")
      if lines <= ScmMessageField.maxLines {
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, "\(lines) 行: 収まる間は先頭の行から見える")
      }
    }
    XCTAssertGreaterThan(field.frame.height, scroll.contentView.bounds.height, "中身は枠より高い")
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "中がスクロールしている")

    scroll.scrollerStyle = .legacy  // 推奨の型が legacy へ変わると、AppKit はこの setter で当て直す
    hosted.pane.layoutSubtreeIfNeeded()
    XCTAssertEqual(field.frame.width, scroll.frame.width, "スクロールバーが字の幅を狭めない")
  }

  /// 欄の上限は 10 行分の高さで、1 行が既定より高い文字（タイ文字）でも低くならない。
  func testTheMessageOfTallLinesStopsAtTheSameHeight() throws {
    let field = MessageTextView(metrics: ScmMessageField.metrics)
    let line = Theme.Layout.editorCommitMessageLine
    field.string = Array(repeating: "ปั้ญู", count: 12).joined(separator: "\n")
    XCTAssertEqual(
      field.fittingHeight(width: 300, maxLines: ScmMessageField.maxLines),
      Theme.Layout.editorCommitMessage + line * CGFloat(ScmMessageField.maxLines - 1),
      accuracy: 0.5)
  }
}
