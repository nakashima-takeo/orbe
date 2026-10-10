import OrbeTestSupport
import XCTest

@testable import Orbe

/// 秘書へ届いたことを確証（貼った後の working）で確かめ、確証が無ければ送り直し、応えなければ人に秘書のタブを指す。
///
/// 壊れると何が起きるか: claude の対話（フォルダの信頼・要約から再開）に貼った頼みが、溜めから消えて失われる。見えない
/// 秘書のタブが対話で止まったまま、人はそこへ行く手掛かりを持たない。
extension SecretaryTests {
  /// 貼られた行をファイルへ足していく偽 claude で起こす（届いた回数を数える）。
  private func launchCounting(_ file: SecretaryFile? = nil) throws -> (WindowController, URL) {
    let log = TestScratch.caseDir.appendingPathComponent("delivered.log")
    let wc = try launch(file, agentBody: "exec /usr/bin/tee -a '\(log.path)' >/dev/null")
    return (wc, log)
  }

  private func deliveries(_ log: URL, _ needle: String) -> Int {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
      .components(separatedBy: "\n").filter { $0.contains(needle) }.count
  }

  func testAnAskIsSentAgainWhenTheNextChangeComesWithoutConfirmation() throws {
    let (wc, log) = try launchCounting()
    _ = try wc.secretary.ask(.text("届いたか確かめる"))
    let tab = try XCTUnwrap(try homeTabs(wc).first)
    report(wc, tab, "idle", "s-1")
    XCTAssertTrue(waitUntil { self.deliveries(log, "届いたか確かめる") == 1 }, "1 度貼る")

    report(wc, tab, "done", "s-1")
    XCTAssertTrue(
      waitUntil { self.deliveries(log, "届いたか確かめる") == 2 }, "確証の無いまま状態が変わったら送り直す")
    XCTAssertEqual(wc.secretary.record.pending.count, 1)

    report(wc, tab, "working", "s-1")
    XCTAssertEqual(wc.secretary.record.pending, [], "確証で溜めから外す")
    report(wc, tab, "done", "s-1")
    XCTAssertFalse(
      waitUntil(1) { self.deliveries(log, "届いたか確かめる") > 2 }, "確証の後は送り直さない")
  }

  /// 起こしてから最初の報告が無い、貼ってから確証が無いまま `patience` が過ぎたら、秘書のタブを指す知らせを出す。
  func testAnUnresponsiveSecretaryIsPointedOutWithItsTab() throws {
    let wc = try launch()
    wc.secretary.patience = 0.3
    _ = try wc.secretary.ask(.text("応えるか"))
    let tab = try XCTUnwrap(try homeTabs(wc).first)

    XCTAssertTrue(
      waitUntil(3) { wc.attentionStore.transient?.secretaryNotice?.tabId == tab.id },
      "起こしてから最初の報告が無い")
    XCTAssertEqual(
      wc.attentionStore.transient?.secretaryNotice?.text,
      wc.localization.string(.secretaryUnresponsive))

    wc.attentionStore.transient = nil
    report(wc, tab, "idle", "s-1")
    XCTAssertTrue(
      waitUntil(3) { wc.attentionStore.transient?.secretaryNotice?.tabId == tab.id },
      "貼ってから確証が無い")

    wc.attentionStore.transient = nil
    report(wc, tab, "working", "s-1")
    XCTAssertFalse(waitUntil(1) { wc.attentionStore.transient != nil }, "確証が来れば知らせない")
  }
}
