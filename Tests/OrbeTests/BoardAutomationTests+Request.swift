import AppKit
import XCTest

@testable import Orbe

/// 自動化の部品の依頼——欄の ↵ で頼む・カードの「修正を依頼」で欄に書き出す・ボードの断り。本物の `BoardView` を実窓に載せ、実 `NSEvent`
/// のキーを届ける。秘書の口は頼みを記録する閉包で、本物の秘書・claude は起きない。
///
/// 壊れると何が起きるか: 頼んだのに欄が残って二度送る。claude が無いのに打った文が消える。↵ を押し続けて同じ頼みで何本も
/// claude が起きる。修正の書き出しが勝手に頼んでしまう・続けて打つと書き出しが消える。
extension BoardAutomationTests {
  private func recording(
    _ model: BoardModel, _ refusal: Secretary.Refusal? = nil
  ) -> () -> [String] {
    var asks: [String] = []
    model.automation.onAsk = {
      asks.append($0)
      return refusal
    }
    return { asks }
  }

  func testEnterInTheFieldAsksTheTypedTextAndEmptiesTheField() {
    let model = board()
    let asks = recording(model)
    let window = mount(model)

    type("abc", to: window)
    send(Key.enter, "\r", to: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(asks(), ["abc"], "押し続けても 1 回")
    XCTAssertEqual(model.automation.requestText, "")
    XCTAssertNil(model.refusal)
  }

  /// カードの「修正を依頼」は、依頼の欄に「自動化「…」の部品「…」の修正：」を書き出して焦点を欄へ移し、まだ頼まない。続けて
  /// 打った文は末尾に足され、↵ で欄からふつうに頼む。
  func testAskToFixDraftsTheRequestInTheField() throws {
    let model = board()
    let automation = model.automation
    let asks = recording(model)
    let window = mount(model)
    down(window)
    right(window)
    let target = try XCTUnwrap(automation.store.automation(Self.failingBacklog))
    let part = try XCTUnwrap(automation.selectedPart)

    automation.draftFix(of: part, l10n: LocalizationStore(language: .ja))
    flush(window)

    let draft = "自動化「\(target.name)」の部品「\(try XCTUnwrap(target.graph.node(part)).entity.name)」の修正："
    XCTAssertEqual(automation.requestText, draft)
    XCTAssertEqual(automation.place, .request)
    XCTAssertEqual(asks(), [], "書き出すだけで頼まない")
    type("x", to: window)
    send(Key.enter, "\r", to: window)
    XCTAssertEqual(asks(), [draft + "x"], "末尾から続けて打てる")
  }

  /// claude が無ければ赤で断り、打った文を残す。断りは次の操作で消える。
  func testWithoutClaudeTheTextStaysAndTheReasonShows() {
    let model = board()
    _ = recording(model, .claudeMissing)
    let window = mount(model)

    type("a", to: window)
    send(Key.enter, "\r", to: window)

    XCTAssertEqual(model.refusal, .boardAskClaudeMissing)
    XCTAssertEqual(model.automation.requestText, "a")
    type("b", to: window)
    XCTAssertNil(model.refusal, "欄に打つと消える")
  }

  /// Home に claude を起こせなければ、依頼できなかったと赤で断り、打った文を残す。
  func testWhenNoAgentCanStartTheTextStaysAndTheReasonShows() {
    let model = board()
    _ = recording(model, .unavailable)

    model.automation.requestText = "a"
    model.automation.send()

    XCTAssertEqual(model.refusal, .boardAskUnavailable)
    XCTAssertEqual(model.automation.requestText, "a")
  }
}
