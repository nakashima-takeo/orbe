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

  private func line(_ ask: SecretaryAsk, task: TaskItem?, _ l10n: LocalizationStore) -> String? {
    let now = date("2026-10-10T01:31:00Z")
    return SecretaryText.body(ask, task: task, l10n: l10n).map {
      SecretaryText.line(
        SecretaryRequest(id: UUID(), receivedAt: now, body: $0), now: now, timeZone: tokyo,
        l10n: l10n)
    }
  }

  func testTypedTextIsOneLineWithTheOriginAndTheTime() {
    XCTAssertEqual(
      line(.text("見積もりを\n山田さんに\t送る"), task: nil, ja),
      "⌘⇧X から · 10:31 — 見積もりを 山田さんに 送る")
    XCTAssertEqual(line(.text("send it"), task: nil, en), "From ⌘⇧X · 10:31 — send it")
  }

  func testATaskAskCarriesTheTaskItsPrimaryLinkAndTheNote() {
    XCTAssertEqual(
      line(.task(id: 12, note: "直して PR まで\n出して"), task: task, ja),
      "⌘⇧X から · 10:31 — タスク 12「Dispatch: fetch 待ちの間 Esc が効かない」(nakashima-takeo/orbe#218) を頼む。"
        + "補足: 直して PR まで 出して")
    var bare = task
    bare.links = []
    XCTAssertEqual(
      line(.task(id: 12, note: "  "), task: bare, ja),
      "⌘⇧X から · 10:31 — タスク 12「Dispatch: fetch 待ちの間 Esc が効かない」を頼む。",
      "結び付きが無ければ括弧を、補足が空なら「補足」を省く")
    XCTAssertNil(line(.task(id: 99, note: ""), task: nil, ja), "消えたタスクは頼めない")
  }

  /// 時刻は受けた時刻で、届ける日と違えば日付も付ける（夜に溜めた頼みが翌朝届く）。
  func testAnAskDeliveredOnAnotherDayShowsTheDate() {
    let request = SecretaryRequest(id: UUID(), receivedAt: date("2026-10-09T13:05:00Z"), body: "a")
    XCTAssertEqual(
      SecretaryText.line(request, now: date("2026-10-10T01:31:00Z"), timeZone: tokyo, l10n: ja),
      "⌘⇧X から · 10/9 22:05 — a")
  }

  func testTheRecordRoundTripsAndABrokenFileIsSetAsideInsteadOfOverwritten() throws {
    let file = SecretaryFile(
      version: SecretaryPersistence.version, sessionId: "s-1",
      pending: [SecretaryRequest(id: UUID(), receivedAt: Date(timeIntervalSince1970: 0), body: "a")]
    )
    SecretaryPersistence.save(file)
    XCTAssertEqual(SecretaryPersistence.load(), file)

    let url = try XCTUnwrap(SecretaryPersistence.fileURL)
    try Data(#"{"version":1,"sessionId":"x; rm -rf /","pending":[]}"#.utf8).write(to: url)
    XCTAssertNil(SecretaryPersistence.load(), "再開に使えない会話 ID は読まない")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "原本は退避する")
  }
}
