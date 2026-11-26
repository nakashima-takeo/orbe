import AppKit
import XCTest

@testable import Orbe

/// 行の高さを決めたメッセージ欄（`MessageTextView.Metrics.lineHeight`）の高さ。ポップアップの入力欄（コミット・レビュー）が使う。
///
/// 壊れると何が起きるか: ポップアップの入力欄が、行を足すたびに、決めた行の高さと違う高さで伸びる。字の高い行（タイ文字）や、
/// 打った行・書きかけを入れ直した行の一方だけ高さが変わり、欄が揺れる。10 行を越えても伸び続け、ポップアップの下に並ぶ失敗の札を押し出す。
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
}
