import SwiftUI
import XCTest

@testable import Orbe

/// メニューバー②の flow（ファイル分割の拡張）。到来（展開・艶・滞留・収縮）と、
/// 取り下げ・②中のクリックの閉じ方を、本物の `MenuBarArrivalDriver` で駆動して撮る
/// （時刻は注入するので実時間を待たない）。滞留の尺を決めるのは収縮を撃つ `expired(at:)` の時刻だけ
/// ——`noteTransient` の `dwell` はこの経路（`MenuBarArrivalDriver`）が読まないので、時刻表と
/// 食い違わない 22 を置くだけ。
extension DesignFlowSnapshotTests {
  /// メニューバー②の到来: 本物の `arrived` / `tick` / `expired` で駆動し（時刻は注入するので
  /// 実時間を待たない）、展開・艶の走査・滞留・収縮の各フレームを撮る。
  /// 01 と 08 が同形で数字だけ違えば「閉じた姿は常に実件数を示す」、開き切りの 04〜06 に数字が
  /// 無ければ「文言表示中は件数を出さない」が画で確かめられる。02 が 01 と同形なのは、到来の
  /// 瞬間に幅も姿も飛ばないこと（1 つのピルに統合した理由そのもの）の証拠。畳まれかけの
  /// 03・07 は件数が途中の濃度で残る——`countFold` は開き具合の関数で、0 になるのは開き切り。
  /// 数字が 2 から 3 へ変わるのは 07（収縮）から。開いていく側はずっと到来時の 2 を見せる。
  /// 畳みかけの 03・07 で中身が**左から連続した 1 塊**（状態グリフは丸ごと・切れ目は 1 箇所だけ）
  /// なら、状態グリフ・WS 名・文言は 1 つの箱として畳まれている——個別に畳むと、同じコマで
  /// 3 つが同時に字の途中で切れた断片になる。
  func testMenubarArrival() throws {
    let t0 = Date()
    let store = AttentionStore()
    let driver = MenuBarArrivalDriver()
    let seeded = [
      AttentionRow(
        paneId: 9001, workspaceName: "orbe-remote-ios", tabTitle: "CI 修復", state: "done",
        message: "build OK — 変更なし", stateChangedAt: t0.addingTimeInterval(-480)),
      AttentionRow(
        paneId: 9002, workspaceName: "api-gateway", tabTitle: "deploy スクリプト整理",
        state: "waiting", message: "ビルド成果物の掃除方法を選んでください。",
        stateChangedAt: t0.addingTimeInterval(-45)),
    ]
    let arriving = AttentionRow(
      paneId: 9003, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
      message: "Bash の許可が必要です — bin/rails db:migrate", stateChangedAt: t0)
    try flow(
      "menubar_arrival", size: NSSize(width: 420, height: 64),
      render: { menuBarSnapshot(store: store, phase: driver.phase) },
      steps: [
        ("quiet", {}),  // ① 減光 ◐・地なし・数字なし
        ("seeded", { store.apply(rows: seeded) }),  // ③ ◐＋件数 2
        (
          "arrive",
          {
            store.noteTransient(arriving, dwell: 22, now: t0)
            driver.arrived(at: t0)
          }
        ),
        (
          "expand_half",
          {
            // 一覧は report 経路の次の coalesce で 3 件へ。開いていく間の②が見せるのは到来した
            // 瞬間の 2 なので、ここで 3 になっても画は動かない（3 が出るのは収縮の 07 から）。
            store.apply(rows: seeded + [arriving])
            driver.tick(now: t0.addingTimeInterval(0.42))
          }
        ),
        ("open", { driver.tick(now: t0.addingTimeInterval(0.84)) }),
        // 艶が**ピルの中ほど**に来る時刻。艶の easing は前のめり（`mbGloss`）なので、走査区間の
        // 時間軸の中点は空間の中点ではない——帯がピル幅の 50% に載るのは進捗 0.33 のあたり。
        ("gloss_mid", { driver.tick(now: t0.addingTimeInterval(1.57)) }),
        ("dwell", { driver.tick(now: t0.addingTimeInterval(5)) }),
        (
          "collapse_half",
          {
            driver.expired(at: t0.addingTimeInterval(22))
            driver.tick(now: t0.addingTimeInterval(22.3))
          }
        ),
        (
          "closed",
          {
            if driver.tick(now: t0.addingTimeInterval(22.6)) { store.transient = nil }
          }
        ),
      ])
  }

  /// 原典ケース①（待ち 0 件 → 新着 1 件）。②が生きている間ずっと `store.count` は 1 なのに、
  /// 00〜03 のどのコマにも数字が無く、04 で初めて「1」が現れる——これが「開くとき仕舞い、
  /// 閉じながら生まれる」の実体で、②が見せるのが**到来した瞬間の件数**である証拠。
  /// 一覧は展開の途中（02）で 1 件へ追いつくが、画は動かない。
  func testMenubarArrivalFirst() throws {
    let t0 = Date()
    let store = AttentionStore()
    let driver = MenuBarArrivalDriver()
    let arriving = AttentionRow(
      paneId: 9101, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
      message: "Bash の許可が必要です", stateChangedAt: t0)
    try flow(
      "menubar_arrival_first", size: NSSize(width: 420, height: 64),
      render: { menuBarSnapshot(store: store, phase: driver.phase) },
      steps: [
        ("quiet", {}),  // ① 減光 ◐・地なし・数字なし
        (
          "arrive",
          {
            store.noteTransient(arriving, dwell: 22, now: t0)  // 到来時の件数は 0
            driver.arrived(at: t0)
          }
        ),
        (
          "expand_half",
          {
            store.apply(rows: [arriving])  // 一覧が 1 件へ追いつく。画は動かない
            driver.tick(now: t0.addingTimeInterval(0.42))
          }
        ),
        ("open", { driver.tick(now: t0.addingTimeInterval(0.84)) }),
        (
          "collapse_half",
          {
            driver.expired(at: t0.addingTimeInterval(22))
            driver.tick(now: t0.addingTimeInterval(22.3))  // ここで初めて「1」が生まれる
          }
        ),
        (
          "closed",
          {
            if driver.tick(now: t0.addingTimeInterval(22.6)) { store.transient = nil }
          }
        ),
      ])
  }

  /// 取り下げ・②中のクリックの閉じ方。滞留満了の収縮（`menubar_arrival` の 07〜08）と**同じ姿**の
  /// コマが並び、違うのは尺だけ（600ms → 180ms）であることを画で確かめる。
  /// 中身は左から畳まれて件数が現れる——中央へ萎んでいくコマがどこにも無いこと自体が、
  /// 即時に閉じる経路を無くした結果（1 フレームで幅が飛ぶと器と content の幅がずれて中央寄せに
  /// 見えた）。
  func testMenubarDismiss() throws {
    let t0 = Date()
    let store = AttentionStore()
    let driver = MenuBarArrivalDriver()
    let arriving = AttentionRow(
      paneId: 9201, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
      message: "Bash の許可が必要です — bin/rails db:migrate", stateChangedAt: t0)
    try flow(
      "menubar_dismiss", size: NSSize(width: 420, height: 64),
      render: { menuBarSnapshot(store: store, phase: driver.phase) },
      steps: [
        (
          "open",
          {
            store.noteTransient(arriving, dwell: 22, now: t0)
            store.apply(rows: [arriving])
            driver.arrived(at: t0)
            driver.tick(now: t0.addingTimeInterval(0.84))
          }
        ),
        // クリック（または取り下げ）。撃った瞬間はまだ開いたまま＝幅は飛ばない。
        ("dismiss", { driver.dismissed(at: t0.addingTimeInterval(5)) }),
        ("collapse_half", { driver.tick(now: t0.addingTimeInterval(5.09)) }),
        (
          "closed",
          {
            if driver.tick(now: t0.addingTimeInterval(5.18)) { store.transient = nil }
          }
        ),
      ])
  }
}

/// メニューバーアイテムを bar 相当の地へ右寄せで置いたスナップショット用ビュー。
/// 実メニューバーと同じ ideal サイズで撮るため、幅は content に決めさせる。
private func menuBarSnapshot(store: AttentionStore, phase: MenuBarArrival.Phase) -> some View {
  MenuBarStatusView(store: store, ui: MenuBarUIState(), phase: phase)
    .fixedSize()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    .padding(.horizontal, Theme.Space.phrase)
    .background(Color.theme.bgBase)
}
