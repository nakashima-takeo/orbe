import XCTest

@testable import Orbe

/// 上のバーの幅の配り方（`EditorBarLayout.slots`）。部品は譲る順（`EditorBarYield`）を名乗り、幅が足りなければ、先に譲る部品
/// から譲る。
///
/// 壊れると何が起きるか: 狭い窓で、右端の主な操作のボタン（コミット・レビュー）より先に中ほどの札が残り、ボタンが押せなく
/// なる。今のファイルの親のパスが収まらないだけで「⌥ 端末を表示」まで消える。後から足した画面ごとの部品が、決めた順と違う順で
/// 譲る。
@MainActor
final class EditorBarLayoutTests: OrbeTestCase {
  private static let spacing: CGFloat = 6

  /// 部品の宣言と、部品が持つ姿の幅（狭い順。先頭が最小の幅）。
  private struct Part {
    let declaration: EditorBarPart
    let faces: [CGFloat]
  }

  /// 使える幅 `available` で配った、部品ごとの使った幅（落とした部品は nil）。部品は、渡された幅に収まるいちばん広い姿を選ぶ。
  private func widths(_ parts: [Part], _ available: CGFloat) -> [CGFloat?] {
    EditorBarLayout.slots(
      parts: parts.map(\.declaration), minimums: parts.map { $0.faces[0] },
      available: available, spacing: Self.spacing
    ) { index, offered in
      parts[index].faces.last { $0 <= offered } ?? parts[index].faces[0]
    }
    .map { $0?.width }
  }

  /// バーを狭めていくと、案内 → 右端のボタンの添え書き → 中ほどの札の広い姿 → 今の項目の広い姿（親のパス、その次に名前の
  /// 全体）→ 中ほどの札まるごと、の順に譲る。開閉・今の項目のボタン・右端のボタンは、最小の幅を割っても落ちない。
  func testNarrowingTheBarYieldsInTheYieldOrderWhileTheUnyieldingPartsStay() {
    let parts = [
      Part(declaration: EditorBarPart(), faces: [26]),
      Part(declaration: EditorBarPart(grows: .itemWide), faces: [40, 120, 200]),
      Part(declaration: EditorBarPart(drops: .chip, grows: .chipWide), faces: [60, 150]),
      Part(declaration: EditorBarPart(side: .trailing, drops: .hint), faces: [100]),
      Part(declaration: EditorBarPart(side: .trailing, grows: .actionDetail), faces: [80, 180]),
    ]
    // 全部の広い姿と、部品ごとの間隔 6 の和は 686。
    XCTAssertEqual(widths(parts, 686), [26, 200, 150, 100, 180], "全部が収まれば、全部が広い姿")
    XCTAssertEqual(widths(parts, 685), [26, 200, 150, nil, 180], "最初に案内が落ちる")
    XCTAssertEqual(widths(parts, 579), [26, 200, 150, nil, 80], "次に右端のボタンの添え書き")
    XCTAssertEqual(widths(parts, 479), [26, 200, 60, nil, 80], "次に中ほどの札の広い姿")
    XCTAssertEqual(widths(parts, 389), [26, 120, 60, nil, 80], "次に今の項目の親のパス")
    XCTAssertEqual(widths(parts, 309), [26, 40, 60, nil, 80], "次に今の項目の名前の全体")
    XCTAssertEqual(widths(parts, 229), [26, 40, nil, nil, 80], "最後に中ほどの札まるごと")
    XCTAssertEqual(widths(parts, 100), [26, 40, nil, nil, 80], "落とさない部品は、最小の幅で残る")
  }

  /// 収まらない部品は、ほかの部品を道連れにしない。今の項目の広い姿が収まらなければ、使わなかった幅は後に譲る部品へ回る。
  /// 大事な側の落とせる部品が収まらなくても、後に譲る部品は収まれば残る。
  func testAPartThatDoesNotFitLeavesTheRestToTheLaterParts() {
    let longPath = [
      Part(declaration: EditorBarPart(), faces: [26]),
      Part(declaration: EditorBarPart(grows: .itemWide), faces: [40, 120, 600]),
      Part(declaration: EditorBarPart(side: .trailing, drops: .hint), faces: [100]),
    ]
    XCTAssertEqual(widths(longPath, 400), [26, 120, 100], "親のパスが収まらなくても、案内は出る")

    let wideChip = [
      Part(declaration: EditorBarPart(), faces: [26]),
      Part(declaration: EditorBarPart(drops: .chip), faces: [300]),
      Part(declaration: EditorBarPart(side: .trailing, drops: .hint), faces: [100]),
    ]
    XCTAssertEqual(widths(wideChip, 200), [26, nil, 100], "中ほどの札が収まらなくても、案内は出る")
  }

  /// 中ほどの札まるごとが落ちると、空いた幅で、先に譲っていた今の項目の名前（幅に合わせて伸び縮みする）が広い姿に戻る。
  func testWhenTheChipDropsTheNameThatYieldedEarlierWidensAgain() {
    let parts = [
      Part(declaration: EditorBarPart(), faces: [26]),
      // 名前は 40 から 400 まで、1 ずつ伸び縮みする。
      Part(
        declaration: EditorBarPart(grows: .itemWide),
        faces: Array(stride(from: 40, through: 400, by: 1))),
      Part(declaration: EditorBarPart(drops: .chip), faces: [60]),
    ]
    // 開閉・名前の最小の幅・札と、間隔の和は 144。
    XCTAssertEqual(widths(parts, 144), [26, 40, 60], "札が入れば、名前は最小の幅")
    XCTAssertEqual(widths(parts, 143), [26, 105, nil], "札が落ちれば、札と間隔の分だけ名前が広がる")
  }
}
