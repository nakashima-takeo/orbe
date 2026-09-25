import SwiftUI
import XCTest

@testable import Orbe

/// 最新化の語（一覧行の同期ピル・失敗した行の理由）が**実際に画へ出ているか**を確かめる。
///
/// builder のテストは「行が `sync` を持っている」までしか言えず、失敗のテストは「モデルが
/// `GitRefreshFailure` を持っている」までしか言えない。View がそれを読むのをやめても、どちらのテストも
/// gallery（書き出すだけで突合しない）も緑のまま通る——その隙間だけをここが塞ぐ。突合は「その語を
/// 抜いた画と違うか」の 1 点に絞る（ピクセル比較の baseline を持たないので、見た目の変更で壊れない）。
@MainActor
final class DispatchRefreshRowRenderTests: SnapshotTestCase {

  private let size = NSSize(width: 480, height: 36)

  /// 遅れが一覧の行に出る。出なければ、ユーザーは古い地点から始まることに気づけない。
  func testLocalBranchRowDrawsTheSyncPill() throws {
    let plain = try render(item())
    XCTAssertEqual(plain, try render(item()), "前提: 同じ行の描画は決定的（違えば以下の比較が無意味になる）")
    XCTAssertNotEqual(
      try render(item(sync: try sync(ahead: 0, behind: 3))), plain,
      "遅れが画に出ていない——builder が載せても View が読まなければ画面から消える")
  }

  /// **差が無い側のピルは立てない。** 両側あるときだけ 2 枚で、`↑0` や `↓0` が無言で場所を取らない。
  func testSyncPillsStandOnlyForTheSideWithCommits() throws {
    let synced = try width(ahead: 0, behind: 0)
    let aheadOnly = try width(ahead: 3, behind: 0)
    let behindOnly = try width(ahead: 0, behind: 3)
    let both = try width(ahead: 3, behind: 3)

    XCTAssertEqual(synced, 0, accuracy: 0.5, "差が無ければ 1 枚も立たない")
    XCTAssertGreaterThan(behindOnly, 0)
    XCTAssertEqual(aheadOnly, behindOnly, accuracy: 0.5, "↑ と ↓ は同じ形の 1 枚")
    // 許容 1.5pt は fittingSize の整数丸めぶん。取りこぼしたら困るのはピル 1 枚（約 27pt）の増減。
    XCTAssertEqual(
      both, aheadOnly + Theme.Space.tick + behindOnly, accuracy: 1.5,
      "両側あるときだけ 2 枚——0 の側が空のピルを占めていない")
  }

  /// **番号チップが立つ行には同期ピルを重ねない**（右クラスタの優先順: 候補件数 → チップ → ノート → 同期）。
  /// Enter の判定は表示と独立なので、この行でも遅れていれば選択画面に入る。
  func testSyncPillYieldsToThePullRequestBadge() throws {
    let sync = try sync(ahead: 0, behind: 3)
    let badges = [DispatchBadge(text: "#142")]
    XCTAssertNotEqual(try render(item(sync: sync)), try render(item()), "前提: ピルは画に出る")
    XCTAssertEqual(
      try render(item(sync: sync, badges: badges)), try render(item(badges: badges)),
      "チップの隣に同期ピルまで並べている")
  }

  /// 失敗した「最新化して作成」の行が**理由を名乗る**。理由が消えると、失敗画面は ✕ だけになって
  /// 何を直せば再試行が通るのか分からなくなる。
  func testFailedRefreshRowDrawsTheReason() throws {
    let host = try failedRow(.fetch(.reason("fatal: could not read from remote repository")))
    XCTAssertEqual(
      host, try failedRow(.fetch(.reason("fatal: could not read from remote repository"))),
      "前提: 同じ行の描画は決定的（違えば以下の比較が無意味になる）")
    XCTAssertNotEqual(
      host, try failedRow(.fetch(.reason("fatal: repository 'origin' not found"))),
      "失敗の理由が画に出ていない")
  }

  // MARK: - ヘルパ

  /// 遅れた `stale`（`origin/stale` を追跡）の同期。`counts` なのでピルの条件を満たす。
  private func sync(ahead: Int, behind: Int) throws -> DispatchBranchSync {
    try XCTUnwrap(
      DispatchBranchSync(
        GitBranch(
          name: "stale", relativeDate: "1d前",
          upstream: GitUpstream(
            short: "origin/stale", ref: "refs/remotes/origin/stale", remote: "origin",
            remoteRef: "refs/heads/stale", track: .counts(ahead: ahead, behind: behind)))))
  }

  private func item(sync: DispatchBranchSync? = nil, badges: [DispatchBadge] = []) -> DispatchItem {
    DispatchItem(
      glyph: .localBranch, name: "stale", detail: "1d前", badges: badges, sync: sync,
      action: .localBranch(name: "stale"))
  }

  private func render(_ item: DispatchItem) throws -> Data {
    try XCTUnwrap(
      renderPNG(
        DispatchRow(item: item, selected: false, onTap: {}, onHoverEnter: {}, onOpenWeb: nil),
        size: size, dark: true))
  }

  /// ピルの組が要求する幅（枚数の契約は画でなく寸法で言う）。
  private func width(ahead: Int, behind: Int) throws -> CGFloat {
    NSHostingView(rootView: DispatchSyncPills(sync: try sync(ahead: ahead, behind: behind)))
      .fittingSize.width
  }

  /// 最新化が落ちた直後の画面の行 0（カーソルは「そのまま作成」へ落ちている）。
  private func failedRow(_ failure: GitRefreshFailure) throws -> Data {
    let model = DispatchRefreshModel(item: item(), sync: try sync(ahead: 0, behind: 3))
    model.beginUpdating()
    model.fail(failure)
    return try XCTUnwrap(
      renderPNG(
        DispatchRefreshRow(model: model, choice: .refreshed, onTap: {}, onHoverEnter: {}),
        size: size, dark: true))
  }
}
