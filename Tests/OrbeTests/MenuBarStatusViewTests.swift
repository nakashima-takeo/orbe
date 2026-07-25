import SwiftUI
import XCTest

@testable import Orbe

/// メニューバーアイテム content（`MenuBarStatusView`）のサイズ契約を固定する。
/// status bar は variableLength でも button 子ビューの制約を幅に読まないため、
/// controller が intrinsic 幅を `statusItem.length` へ明示反映する——その前提として
/// content の intrinsic が「幅正・高さ ≤ bar 厚の最小 22pt」であることをここで守る
/// （高さ超過は 22pt bar で縦潰れ＝実機で空白/崩れに見えた回帰の再発防止）。
@MainActor
final class MenuBarStatusViewTests: XCTestCase {

  private func fittingSize(store: AttentionStore, ui: MenuBarUIState = MenuBarUIState()) -> NSSize {
    let host = NSHostingView(rootView: MenuBarStatusView(store: store, ui: ui))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func row(state: String, message: String? = nil) -> AttentionRow {
    AttentionRow(
      paneId: 1, workspaceName: "ws", tabTitle: "tab", state: state, message: message,
      stateChangedAt: Date())
  }

  /// ① 静か（要対応 0）: グリフのみでも幅正・高さ 22 以下。
  func testQuietStateFitsMenuBar() {
    let size = fittingSize(store: AttentionStore())
    XCTAssertGreaterThan(size.width, 0)
    XCTAssertLessThanOrEqual(size.height, 22)
  }

  /// ③ 収縮ピル（◐＋件数）: 高さ 22 以下・グリフ単体より幅が広い。
  func testCountPillFitsMenuBar() {
    let store = AttentionStore()
    store.rows = [row(state: "waiting"), row(state: "done")]
    let size = fittingSize(store: store)
    XCTAssertGreaterThan(size.width, fittingSize(store: AttentionStore()).width)
    XCTAssertLessThanOrEqual(size.height, 22)
  }

  /// transient を 1 件だけ載せた store。
  private func transientStore(workspace: String, message: String) -> AttentionStore {
    let store = AttentionStore()
    store.noteTransient(
      AttentionRow(
        paneId: 1, workspaceName: workspace, tabTitle: "tab", state: "waiting", message: message,
        stateChangedAt: Date()))
    return store
  }

  /// 提案幅 `proposedWidth` を与えたときにレイアウトが取る幅。`fittingSize` は理想値の総和で、
  /// レイアウトが提案幅にどう反応するかを写さない——短い内容で膨らむ破れはここでしか捕まらない。
  private func renderedWidth(store: AttentionStore, proposedWidth: CGFloat) -> CGFloat {
    NSHostingController(rootView: MenuBarStatusView(store: store, ui: MenuBarUIState()))
      .sizeThatFits(in: NSSize(width: proposedWidth, height: 40)).width
  }

  /// ② 滲み出しピル（WS 名＋文言）: 高さ 22 以下。静的状態（①③）より確実に広い
  /// ＝transient 出現で幅が伸びる契約（実機で伸びなかった回帰の再発防止）。
  /// 幅の上限は `testTransientPillCapsOverallWidth` が単独で持つ。
  func testTransientPillFitsMenuBarAndExpands() {
    let store = AttentionStore()
    let long = String(repeating: "とても長い文言 ", count: 40)
    store.rows = [row(state: "waiting"), row(state: "done")]
    store.noteTransient(row(state: "waiting", message: long))
    let size = fittingSize(store: store)
    XCTAssertLessThanOrEqual(size.height, 22)

    let quietWidth = fittingSize(store: AttentionStore()).width
    let countStore = AttentionStore()
    countStore.rows = [row(state: "waiting"), row(state: "done")]
    let countWidth = fittingSize(store: countStore).width
    XCTAssertGreaterThan(size.width, countWidth, "transient は収縮ピル（③）より広く滲み出る")
    XCTAssertGreaterThan(size.width, quietWidth, "transient は静的グリフ（①）より広く滲み出る")
  }

  /// 長い WS 名＋長文でもピル全体が幅上限を超えない（メニューバーの他アイテムを圧迫しない）。
  func testTransientPillCapsOverallWidth() {
    let store = AttentionStore()
    let longRow = AttentionRow(
      paneId: 1, workspaceName: String(repeating: "workspace-name-", count: 10),
      tabTitle: "tab", state: "waiting",
      message: String(repeating: "とても長い文言 ", count: 40), stateChangedAt: Date())
    store.noteTransient(longRow)
    let size = fittingSize(store: store)
    // 上限＝ピル cap ＋ 外側の水平 padding（hair×2）。
    XCTAssertLessThanOrEqual(
      size.width, MenuBarStatusView.transientMaxWidth + Theme.Space.hair * 2)
    XCTAssertLessThanOrEqual(size.height, 22)
  }

  /// ② 滲み出しピルは**提案幅に依存しない**。intrinsic より十分広い提案を与えても取る幅が
  /// intrinsic のままなら、幅は内容だけで決まっており、提案幅を子へ流して膨らませるコンテナ
  /// （＝修正前の HStack ＋ flexible frame）が再導入されていない。
  ///
  /// これは提案幅非依存だけを見る——両辺とも同じ `sizeThatFits` に由来するので、
  /// **スロットが内容へハグするか**は別に固定する必要がある（`…WorkspaceSlotHugsName` /
  /// `…ShrinksForShortMessage`）。
  func testTransientPillHugsContentRegardlessOfProposedWidth() {
    for (ws, message) in [
      (shortWS, longMessage), (shortWS, shortMessage),
      (longWS, longMessage), (longWS, shortMessage),
    ] {
      let store = transientStore(workspace: ws, message: message)
      XCTAssertEqual(
        renderedWidth(store: store, proposedWidth: 500), fittingSize(store: store).width,
        accuracy: 2, "ws=\(ws) message=\(message): 広い提案でも内容幅へハグする")
    }
  }

  /// WS 名が短いぶんの幅は本文が吸う。本文が長ければ、WS 名の長短にかかわらずピルは
  /// 予算を使い切る＝同じ幅になる（WS 名が短いときだけピルが痩せる＝文言を出し切れて
  /// いない、ということが起きない）。
  func testTransientPillGivesSpareWidthToMessage() {
    XCTAssertEqual(
      fittingSize(store: transientStore(workspace: shortWS, message: longMessage)).width,
      fittingSize(store: transientStore(workspace: longWS, message: longMessage)).width,
      accuracy: 2, "長い本文では WS 名の長短によらず予算を使い切る")
  }

  /// WS 名スロットは上限の範囲で**内容へハグする**。同じ本文なら、WS 名が短いピルは長い
  /// ピルより総幅が小さい。スロットが内容と無関係に上限いっぱいを取る実装（＝WS 名の右に
  /// 空白が出る、報告された不具合そのもの）だと両者が同じ総幅になるので、この不等号で落ちる。
  ///
  /// 本文は短い方を使う——長文だと双方が予算を使い切って総幅が並び、WS 名スロットの差が
  /// 総幅に現れない。
  func testTransientPillWorkspaceSlotHugsName() {
    XCTAssertLessThan(
      fittingSize(store: transientStore(workspace: shortWS, message: shortMessage)).width,
      fittingSize(store: transientStore(workspace: longWS, message: shortMessage)).width,
      "WS 名が短ければピルはそのぶん狭い（スロットが上限いっぱいを取らない）")
  }

  /// 本文スロットも**内容へハグする**＝短い本文で残り予算を吸い切らない。
  ///
  /// 上界 250 の根拠: 本文が内容で止まる限り、ピルは「固定部（◐ 15＋状態グリフ 11＋spacing
  /// 6×3＋padding 8×2＋外側 hair 2×2＝64）＋上限で頭打ちの WS 名スロット（≤120）＋短い本文」
  /// までしか伸びない＝約 200（実測 201）。250 はそこへ文言差・サブピクセル分の余裕を足した値で、
  /// 一方「本文が残り予算を吸い切る」破れは WS 名の長短によらず必ず上限 334
  /// （`transientMaxWidth` ＋ hair×2）へ張り付くため、その間で確実に切り分けられる。
  func testTransientPillShrinksForShortMessage() {
    for ws in [shortWS, longWS] {
      XCTAssertLessThan(
        fittingSize(store: transientStore(workspace: ws, message: shortMessage)).width, 250,
        "ws=\(ws): 短い本文では残り予算を吸わずピルが縮む")
    }
  }
}

private let shortWS = "orbe"
private let longWS = "very-long-workspace-name-here-xxx"
private let shortMessage = "完了"
private let longMessage = "Bash の許可が必要です — bin/rails db:migrate（スキーマに 2 テーブル追加）"
