import XCTest

@testable import Orbe

/// ⌘↵（秘書に頼む）を、選択の同一性の上で固定する。入力の行き先なら打った文を頼んで入力欄を空にし、タスクの行なら
/// 直下の頼む欄を開き、欄の ↵ で補足ごと頼む。欄は離れたら送らずに捨てる。頼んでもタスクは増えず、画面は開いたまま。
///
/// 壊れると何が起きるか: ⌘↵ がタスクを足してしまう・選んでいない行のタスクを頼む。別の行をクリックしただけで書きかけの
/// 補足が秘書に届く。claude が無いのに入力が消えて頼みが失われる。
extension TaskPaletteModelTests {
  /// 頼みを記録し、`result` を返す秘書。
  private func recording(
    _ palette: TaskPaletteModel,
    _ result: Result<Secretary.Acceptance, Secretary.Refusal> = .success(.accepted)
  ) -> () -> [SecretaryAsk] {
    var asks: [SecretaryAsk] = []
    palette.onAskSecretary = {
      asks.append($0)
      return result
    }
    return { asks }
  }

  func testCommandEnterOnTheDestinationAsksTheTypedTextAndClearsTheField() {
    let palette = threeTodos()
    let asks = recording(palette)
    palette.query = "  見積もりを山田さんに送る "
    XCTAssertEqual(palette.selectedID, .add)

    palette.askSecretary()

    XCTAssertEqual(asks(), [.text("見積もりを山田さんに送る")])
    XCTAssertEqual(palette.store.tasks.count, 3, "タスクは増えない")
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.notice, .asked)
    palette.move(1)
    XCTAssertNil(palette.notice, "次の操作で消える")
  }

  func testAQueuedAskSaysItArrivesWhenTheSecretaryIsFree() {
    let palette = threeTodos()
    _ = recording(palette, .success(.queued))
    palette.query = "x"

    palette.askSecretary()

    XCTAssertEqual(palette.notice, .askedQueued)
  }

  func testWithoutClaudeTheTextStaysAndTheReasonShows() {
    let palette = threeTodos()
    _ = recording(palette, .failure(.claudeMissing))
    palette.query = "見積もり"

    palette.askSecretary()

    XCTAssertEqual(palette.query, "見積もり", "打った文は残す")
    XCTAssertEqual(palette.error, .secretaryClaude)
  }

  /// タスクの行の ⌘↵ は直下に頼む欄を開き、↵ でそのタスクを補足ごと頼んで欄を閉じる。
  func testCommandEnterOnATaskRowOpensTheAskAndEnterSendsTheTaskWithTheNote() {
    let palette = threeTodos()
    let asks = recording(palette)
    palette.move(1)

    palette.askSecretary()
    XCTAssertEqual(palette.askingTaskID, 2)
    XCTAssertEqual(palette.focusTarget, .ask)
    XCTAssertTrue(palette.rows.contains(.ask(TaskPaletteAskRow(taskID: 2, label: "b"))))

    palette.draftText = "直して PR まで出して"
    palette.sendAsk()

    XCTAssertEqual(asks(), [.task(id: 2, note: "直して PR まで出して")])
    XCTAssertNil(palette.draft, "欄を閉じる")
    XCTAssertEqual(palette.selectedID, .task(2))
    XCTAssertEqual(palette.notice, .asked)
  }

  /// 頼む欄は、別の行のクリックや範囲の切り替えで離れたら、何も送らずに捨てる。
  func testLeavingTheAskDiscardsItWithoutSending() {
    let palette = threeTodos()
    let asks = recording(palette)
    palette.move(1)

    palette.askSecretary()
    palette.draftText = "書きかけ"
    palette.tapRow(.task(3))
    XCTAssertNil(palette.draft)

    palette.openAsk(1)
    palette.draftText = "書きかけ"
    palette.toggleScope()
    XCTAssertNil(palette.draft)

    XCTAssertEqual(asks(), [], "何も送らない")
  }

  /// 完了の見出し・GitHub タブでは何もしない。
  func testCommandEnterElsewhereDoesNothing() {
    let palette = model([task(1, "a", .done)])
    let asks = recording(palette)
    XCTAssertEqual(palette.selectedID, .doneHeader)

    palette.askSecretary()
    palette.setTab(.github)
    palette.askSecretary()

    XCTAssertEqual(asks(), [])
    XCTAssertNil(palette.draft)
  }

  /// 行き先の段の右端は、足したタスクが入る先（範囲で workspace が変わる）。
  func testTheDestinationPlaceFollowsTheScope() {
    let palette = threeTodos()
    let l10n = LocalizationStore(language: .ja)

    XCTAssertEqual(palette.destinationPlace(l10n), "未着手 · 中の先頭 · workspace なし")
    palette.setScope(.opened)
    XCTAssertEqual(palette.destinationPlace(l10n), "未着手 · 中の先頭 · orbe")
  }
}
