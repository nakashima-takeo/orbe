import AppKit
import XCTest

@testable import Orbe

/// 自動追加の部品の依頼——欄の ↵ で頼む・一覧の ⌘↵ で直しを頼む・ボードの断り。本物の `BoardView` を実窓に載せ、実 `NSEvent`
/// のキーを届ける。秘書の口は頼みを記録する閉包で、本物の秘書・claude は起きない。
///
/// 壊れると何が起きるか: 頼んだのに欄が残って二度送る。消えた自動追加の直しを秘書へ渡す。claude が無いのに打った文が消える。
/// ↵・⌘↵ を押し続けて同じ頼みが何件も溜まる。
extension BoardIntakeTests {
  private func recording(
    _ model: BoardModel, _ refusal: Secretary.Refusal? = nil
  ) -> () -> [SecretaryAsk] {
    var asks: [SecretaryAsk] = []
    model.intake.onAsk = {
      asks.append($0)
      return refusal
    }
    return { asks }
  }

  func testEnterInTheFieldAsksForANewAutoAddAndEmptiesTheField() {
    let model = board()
    let asks = recording(model)
    let window = mount(model)

    type("abc", to: window)
    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(asks(), [.intake("abc")], "押し続けても 1 回")
    XCTAssertEqual(model.intake.requestText, "")
    XCTAssertNil(model.refusal)
  }

  /// ⌘↵ は選んでいる自動追加の直しをその場で頼み、焦点は一覧に残る。押し続けても 1 回。
  func testCommandEnterAsksToFixTheSelectedAutoAddAtOnce() throws {
    let model = board()
    let intake = model.intake
    let asks = recording(model)
    let window = mount(model)
    down(window)

    press(Key.enter, "\r", .command, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)

    let target = try XCTUnwrap(intake.store.intake(Self.failingBacklog))
    XCTAssertEqual(asks(), [.intakeFix(target)])
    XCTAssertEqual(intake.place, .list)
    XCTAssertNil(model.refusal)
  }

  /// 選んでいる自動追加が頼む前に消えていたら、係へ渡さずに赤で断る。
  func testAFixWhoseAutoAddWasDeletedIsRefused() throws {
    let model = board()
    let intake = model.intake
    let asks = recording(model)
    intake.move(1)
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "前提")

    try intake.runner.delete(Self.failingBacklog)
    intake.askFix()

    XCTAssertEqual(asks(), [])
    XCTAssertEqual(model.refusal, .boardAskFixGone)
  }

  /// claude が無ければ赤で断り、打った文を残す。断りは次の操作で消える。
  func testWithoutClaudeTheTextStaysAndTheReasonShows() {
    let model = board()
    _ = recording(model, .claudeMissing)
    let window = mount(model)

    type("a", to: window)
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(model.refusal, .boardAskClaudeMissing)
    XCTAssertEqual(model.intake.requestText, "a")
    type("b", to: window)
    XCTAssertNil(model.refusal, "欄に打つと消える")

    down(window)
    press(Key.enter, "\r", .command, to: window)
    XCTAssertEqual(model.refusal, .boardAskClaudeMissing, "⌘↵ の直しも同じく断る")
    down(window)
    XCTAssertNil(model.refusal, "↓ で消える")
  }
}
