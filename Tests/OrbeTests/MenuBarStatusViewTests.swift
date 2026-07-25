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

  /// 提案幅 `proposedWidth` を与えて実際に描画させ、view が取った幅を測る。
  /// `fittingSize` は理想値の総和で、レイアウトが提案幅にどう反応するかを写さない
  /// ——短い内容で膨らむ破れはここでしか捕まらない。
  private func renderedWidth(store: AttentionStore, proposedWidth: CGFloat) -> CGFloat {
    let box = WidthBox()
    let root = MenuBarStatusView(store: store, ui: MenuBarUIState())
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear { box.value = geo.size.width }
            .onChange(of: geo.size.width) { _, new in box.value = new }
        })
    let frame = NSRect(x: 0, y: 0, width: proposedWidth, height: 40)
    let host = NSHostingView(rootView: root)
    host.frame = frame
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSView(frame: frame)
    window.contentView?.addSubview(host)
    window.orderFront(nil)
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))  // SwiftUI の描画コミット待ち
    window.orderOut(nil)
    return box.value
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

  /// ② 滲み出しピルは**提案幅に依存せず内容幅へハグする**。intrinsic より十分広い提案を
  /// 与えても実描画幅が intrinsic のままなら、各スロットは内容幅（上限は自分の cap か残り予算）で
  /// 確定しており、内容と無関係にスロットが広がる（＝タイトルと本文の間に空白が出る／本文の右に
  /// 空白が出る）ことはない。本文が短いときピルが縮む契約もここで担保される。
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
}

/// 実描画幅の受け皿（GeometryReader からテストへ値を返すだけ）。
@MainActor private final class WidthBox { var value: CGFloat = -1 }

private let shortWS = "orbe"
private let longWS = "very-long-workspace-name-here-xxx"
private let shortMessage = "完了"
private let longMessage = "Bash の許可が必要です — bin/rails db:migrate（スキーマに 2 テーブル追加）"
