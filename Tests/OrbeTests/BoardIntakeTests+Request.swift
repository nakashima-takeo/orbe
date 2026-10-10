import AppKit
import XCTest

@testable import Orbe

/// 自動追加の部品の依頼の欄——↵ で頼む・⌘↵ で直しを頼む・札の外れ方・ボードの知らせ。本物の `BoardView` を実窓に載せ、実
/// `NSEvent` のキーを届ける。秘書の口は頼みを記録する閉包で、本物の秘書・claude は起きない。
///
/// 壊れると何が起きるか: 頼んだのに欄が残って二度送る。⌘↵ の札が残ったまま新しい依頼が直しとして届く。消えた自動追加の直しを
/// 秘書へ渡す。claude が無いのに打った文が消える。↵ を押し続けて同じ頼みが何件も溜まる。
extension BoardIntakeTests {
  private func recording(
    _ model: BoardModel,
    _ result: Result<Secretary.Acceptance, Secretary.Refusal> = .success(.accepted)
  ) -> () -> [SecretaryAsk] {
    var asks: [SecretaryAsk] = []
    model.intake.onAsk = {
      asks.append($0)
      return result
    }
    return { asks }
  }

  func testEnterInTheFieldAsksForANewAutoAddAndEmptiesTheField() {
    let model = board()
    let asks = recording(model)
    let window = mount(model)

    press(Key.tab, "\t", to: window)
    type("abc", to: window)
    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(asks(), [.intake("abc")], "押し続けても 1 回")
    XCTAssertEqual(model.intake.request, BoardIntakeRequest())
    XCTAssertEqual(model.notice, BoardNotice(message: .boardAsked, tone: .quiet))
    type("d", to: window)
    XCTAssertNil(model.notice, "欄に打つと消える")
  }

  func testAQueuedAskSaysItArrivesWhenFree() {
    let model = board()
    _ = recording(model, .success(.queued))
    let window = mount(model)

    press(Key.tab, "\t", to: window)
    type("a", to: window)
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(model.notice, BoardNotice(message: .boardAskedQueued, tone: .quiet))
  }

  /// ⌘↵ は選んでいる自動追加の札を付けて欄へ移り、↵ でその直しを補足ごと頼んで札を外す。
  func testCommandEnterAsksToFixTheSelectedAutoAdd() throws {
    let model = board()
    let intake = model.intake
    let asks = recording(model)
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)
    XCTAssertEqual(intake.place, .request)
    let target = try XCTUnwrap(intake.store.intake(Self.failingBacklog))
    XCTAssertEqual(
      intake.request.fix, BoardIntakeRequest.Fix(id: target.id, name: target.definition.name))
    XCTAssertEqual(intake.hints.map(\.label), [.boardAskFixHint, .boardHintCancel])

    type("x", to: window)
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(asks(), [.intakeFix(target, note: "x")])
    XCTAssertEqual(intake.request, BoardIntakeRequest(), "欄が空になり札が外れる")
  }

  /// 札は欄から一覧へ移ると外れ（打った文字は残る）、次の ↵ は新しい依頼になる。
  func testLeavingTheFieldDropsTheFixButKeepsTheText() {
    let model = board()
    let intake = model.intake
    let asks = recording(model)
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)
    type("y", to: window)
    press(Key.escape, "\u{1B}", to: window)

    XCTAssertEqual(intake.place, .list)
    XCTAssertNil(intake.request.fix)
    XCTAssertEqual(intake.request.text, "y")

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.hints.map(\.label), [.boardAskHint, .boardHintToList])
    press(Key.enter, "\r", to: window)
    XCTAssertEqual(asks(), [.intake("y")])
  }

  /// 直す相手が送る前に消えていたら、係へ渡さずに赤で断り、欄と札を残す。
  func testAFixWhoseAutoAddWasDeletedIsRefused() throws {
    let model = board()
    let intake = model.intake
    let asks = recording(model)
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)
    type("z", to: window)
    try intake.runner.delete(Self.failingBacklog)
    flush(window)
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(asks(), [])
    XCTAssertEqual(model.notice, BoardNotice(message: .boardAskFixGone, tone: .danger))
    XCTAssertEqual(intake.request.fix?.id, Self.failingBacklog)
    XCTAssertEqual(intake.request.text, "z")
  }

  /// claude が無ければ赤で断り、打った文を残す。
  func testWithoutClaudeTheTextStaysAndTheReasonShows() {
    let model = board()
    _ = recording(model, .failure(.claudeMissing))
    let window = mount(model)

    press(Key.tab, "\t", to: window)
    type("a", to: window)
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(model.notice, BoardNotice(message: .boardAskClaudeMissing, tone: .danger))
    XCTAssertEqual(model.intake.request.text, "a")
    press(Key.tab, "\t", to: window)
    XCTAssertNil(model.notice, "⇥ で消える")
  }
}
