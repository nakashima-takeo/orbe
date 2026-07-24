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

  /// ② 滲み出しピル（WS 名＋文言）: 高さ 22 以下・文言は maxWidth cap で無限に伸びない。
  /// 静的状態（①③）より確実に広い＝transient 出現で幅が伸びる契約（実機で伸びなかった回帰の再発防止）。
  func testTransientPillFitsMenuBarAndExpands() {
    let store = AttentionStore()
    let long = String(repeating: "とても長い文言 ", count: 40)
    store.rows = [row(state: "waiting"), row(state: "done")]
    store.noteTransient(row(state: "waiting", message: long))
    let size = fittingSize(store: store)
    XCTAssertLessThanOrEqual(size.height, 22)
    XCTAssertLessThanOrEqual(size.width, 300, "文言は maxWidth 150 で cap され幅が暴れない")

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
}
