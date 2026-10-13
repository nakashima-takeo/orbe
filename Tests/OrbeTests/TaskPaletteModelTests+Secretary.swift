import XCTest

@testable import Orbe

/// 入力の行き先の ⌘↵（agent に任せる）。打った文を秘書の係へ渡し、受けたら入力欄を空にする。受けなければ打った文を残す。
///
/// 壊れると何が起きるか: ⌘↵ がタスクを足してしまう。claude が無いのに入力が消えて頼みが失われる。
extension TaskPaletteModelTests {
  /// 頼みを記録し、`refusal` を返す秘書。
  private func recording(_ palette: TaskPaletteModel, _ refusal: Secretary.Refusal? = nil)
    -> () -> [SecretaryAsk]
  {
    var asks: [SecretaryAsk] = []
    palette.onAskSecretary = {
      asks.append($0)
      return refusal
    }
    return { asks }
  }

  func testHandingTheTypedTextToAnAgentAsksItAndClearsTheField() {
    let palette = threeTodos()
    let asks = recording(palette)
    palette.query = "  見積もりを山田さんに送る "
    XCTAssertEqual(palette.selectedID, .add)

    palette.askWithQuery()

    XCTAssertEqual(asks(), [.text("見積もりを山田さんに送る")])
    XCTAssertEqual(palette.store.tasks.count, 3, "タスクは増えない")
    XCTAssertEqual(palette.query, "")
  }

  func testWithoutClaudeTheTextStaysAndTheReasonShows() {
    let palette = threeTodos()
    _ = recording(palette, .claudeMissing)
    palette.query = "見積もり"

    palette.askWithQuery()

    XCTAssertEqual(palette.query, "見積もり", "打った文は残す")
    XCTAssertEqual(palette.error, .secretaryClaude)
  }

  func testWhenNoAgentCanStartTheTextStaysAndTheReasonShows() {
    let palette = threeTodos()
    _ = recording(palette, .unavailable)
    palette.query = "見積もり"

    palette.askWithQuery()

    XCTAssertEqual(palette.query, "見積もり", "打った文は残す")
    XCTAssertEqual(palette.error, .secretaryUnavailable)
  }

  /// 空の頼み（制御文字だけ）は黙って受けない——赤字を出さず、打った文も残す。
  func testAnEmptyAskIsSilentAndKeepsTheText() {
    let palette = threeTodos()
    _ = recording(palette, .empty)
    palette.query = "x"

    palette.askWithQuery()

    XCTAssertEqual(palette.query, "x", "打った文は残す")
    XCTAssertNil(palette.error)
  }
}
