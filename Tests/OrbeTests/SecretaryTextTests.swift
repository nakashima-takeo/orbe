import XCTest

@testable import Orbe

/// 秘書へ届ける 1 行の文面と、秘書の記録の読み書きを固定する。
///
/// 壊れると何が起きるか: 複数行の頼みを貼って claude が「[Pasted text]」に畳み、出どころもタスクも見えなくなる。
/// 昨日溜めた頼みが今日の時刻に見える。壊れた secretary.json の上に保存して、人が打った頼みが消える。
@MainActor
final class SecretaryTextTests: OrbeTestCase {
  private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
  private let ja = LocalizationStore(language: .ja)
  private let en = LocalizationStore(language: .en)

  private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
  }

  private var task: TaskItem {
    var item = TaskPaletteSamples.task(12, "Dispatch: fetch 待ちの間 Esc が効かない", .todo) { _ in }
    item.links = [
      TaskLink(
        item: GitHubItemID(repo: "nakashima-takeo/orbe", number: 218)!, kind: .issue)
    ]
    return item
  }

  private func line(
    _ ask: SecretaryAsk, from origin: SecretaryOrigin = .palette, _ l10n: LocalizationStore
  ) -> String? {
    let now = date("2026-10-10T01:31:00Z")
    return SecretaryText.body(ask, l10n: l10n).map {
      SecretaryText.line(
        SecretaryRequest(id: UUID(), receivedAt: now, origin: origin, body: $0), now: now,
        timeZone: tokyo,
        l10n: l10n)
    }
  }

  func testTypedTextIsOneLineWithTheOriginAndTheTime() {
    XCTAssertEqual(
      line(.text("見積もりを\n山田さんに\t送る"), ja),
      "⌘⇧X から · 10:31 — 見積もりを 山田さんに 送る")
    XCTAssertEqual(line(.text("send it"), en), "From ⌘⇧X · 10:31 — send it")
  }

  /// 秘書の会話が付けた待ちの続きからは、出どころを「待ちの条件」にして 1 行に畳む。
  func testWhatHappenedToTheSecretarysWaitIsOneLineFromTheWaitCondition() {
    XCTAssertEqual(
      line(.text("PR #214 にレビューが付いた\n確認の出力:\nLGTM"), from: .wait, ja),
      "待ちの条件 · 10:31 — PR #214 にレビューが付いた 確認の出力: LGTM")
    XCTAssertEqual(line(.text("done"), from: .wait, en), "Wait condition · 10:31 — done")
  }

  func testATaskAskCarriesTheTaskItsPrimaryLinkAndTheNote() {
    XCTAssertEqual(
      line(.task(task, note: "直して PR まで\n出して"), ja),
      "⌘⇧X から · 10:31 — タスク 12「Dispatch: fetch 待ちの間 Esc が効かない」(nakashima-takeo/orbe#218) を頼む。"
        + "補足: 直して PR まで 出して")
    var bare = task
    bare.links = []
    XCTAssertEqual(
      line(.task(bare, note: "  "), ja),
      "⌘⇧X から · 10:31 — タスク 12「Dispatch: fetch 待ちの間 Esc が効かない」を頼む。",
      "結び付きが無ければ括弧を、補足が空なら「補足」を省く")
  }

  /// Home のボードからの頼みは、自動化の新しい依頼か直しとして 1 行で意味が通る（既存の秘書の会話は指示の改版を知らない）。
  func testBoardAsksNameTheAutomationInTheLineItself() {
    XCTAssertEqual(
      line(.automation("Slack の自分宛ての DM を\nタスクの候補にして"), from: .board, ja),
      "Home のボードから · 10:31 — 自動化を頼む: Slack の自分宛ての DM を タスクの候補にして")
    XCTAssertEqual(
      line(.automation("watch my DMs"), from: .board, en),
      "From the Home board · 10:31 — Automation request: watch my DMs")
    XCTAssertNil(line(.automation(" \n "), from: .board, ja), "空の依頼は頼めない")

    let automation = DesignSceneFixtures.boardAutomations()[2]
    XCTAssertEqual(
      line(.automationFix(automation), from: .board, ja),
      "Home のボードから · 10:31 — 自動化 \(automation.id)「\(automation.definition.name)」を直す。")
    XCTAssertEqual(
      line(.automationFix(automation), from: .board, en),
      "From the Home board · 10:31 — Fix automation \(automation.id) “\(automation.definition.name)”."
    )
  }

  /// 時刻は受けた時刻で、届ける日と違えば日付も付ける（夜に溜めた頼みが翌朝届く）。
  func testAnAskDeliveredOnAnotherDayShowsTheDate() {
    let request = SecretaryRequest(
      id: UUID(), receivedAt: date("2026-10-09T13:05:00Z"), origin: .palette, body: "a")
    XCTAssertEqual(
      SecretaryText.line(request, now: date("2026-10-10T01:31:00Z"), timeZone: tokyo, l10n: ja),
      "⌘⇧X から · 10/9 22:05 — a")
  }

  func testTheRecordRoundTripsAndABrokenFileIsSetAsideInsteadOfOverwritten() throws {
    let file = SecretaryFile(
      version: SecretaryPersistence.version, sessionId: "s-1",
      pending: [
        SecretaryRequest(
          id: UUID(), receivedAt: Date(timeIntervalSince1970: 0), origin: .palette, body: "a")
      ]
    )
    SecretaryPersistence.save(file)
    XCTAssertEqual(SecretaryPersistence.load(), file)

    let url = try XCTUnwrap(SecretaryPersistence.fileURL)
    try Data(#"{"version":1,"sessionId":"x; rm -rf /","pending":[]}"#.utf8).write(to: url)
    XCTAssertNil(SecretaryPersistence.load(), "再開に使えない会話 ID は読まない")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "原本は退避する")
  }

  /// 出どころは保存した値（palette・board・wait）のまま読める——値の綴りが変わると、溜まった頼みが次の起動で退避に落ちる。
  func testEachOriginIsReadFromItsSavedValue() throws {
    let url = try XCTUnwrap(SecretaryPersistence.fileURL)
    let records = ["palette", "board", "wait"].map { origin in
      #"{"id":"\#(UUID().uuidString)","receivedAt":"2026-10-10T01:31:00Z","#
        + #""origin":"\#(origin)","body":"a"}"#
    }
    try Data((#"{"version":1,"pending":["# + records.joined(separator: ",") + "]}").utf8)
      .write(to: url)

    XCTAssertEqual(SecretaryPersistence.load()?.pending.map(\.origin), [.palette, .board, .wait])
  }

  /// 知らない出どころ（新しいビルドが書いた値）の記録は使えない原本として退避し、空で始める——直後の保存で溜まった頼みを
  /// 潰さない。
  func testAnUnknownOriginIsSetAsideWithTheOriginalKept() throws {
    let url = try XCTUnwrap(SecretaryPersistence.fileURL)
    let request =
      #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","receivedAt":"2026-10-10T01:31:00Z","#
      + #""origin":"slack","body":"a"}"#
    let original = Data((#"{"version":1,"pending":["# + request + "]}").utf8)
    try original.write(to: url)

    XCTAssertNil(SecretaryPersistence.load(), "空で始める")

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "原位置には残さない")
    let directory = url.deletingLastPathComponent()
    let broken = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("secretary-broken-") && $0.hasSuffix(".json") }
    XCTAssertEqual(broken.count, 1, "退避物が 1 件")
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(broken.first))), original,
      "原本のまま退避する")
  }
}
