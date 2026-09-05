import SwiftUI
import XCTest

@testable import Orbe

/// メニューバーアイテム content（`MenuBarStatusView`）のサイズ契約を固定する。
/// status bar は variableLength でも button 子ビューの制約を幅に読まないため、
/// controller が intrinsic 幅を `statusItem.length` へ明示反映する——その前提として
/// content の intrinsic が「幅正・高さ ≤ bar 厚の最小 22pt」であることをここで守る
/// （高さ超過は 22pt bar で縦潰れ＝実機で空白/崩れに見えた回帰の再発防止）。
@MainActor
final class MenuBarStatusViewTests: OrbeTestCase {

  /// ここが測るのは姿と幅で滞留ではない——`noteTransient` の必須引数を 1 箇所に閉じる。
  private let anyDwell: TimeInterval = 7

  private func fittingSize(
    store: AttentionStore, phase: MenuBarArrival.Phase, ui: MenuBarUIState = MenuBarUIState()
  ) -> NSSize {
    let host = NSHostingView(rootView: MenuBarStatusView(store: store, ui: ui, phase: phase))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func row(tabId: Int = 1, state: String, message: String? = nil) -> AttentionRow {
    AttentionRow(
      tabId: tabId, workspaceName: "ws", tabTitle: "tab", state: state, message: message,
      stateChangedAt: Date())
  }

  /// ① 静か（要対応 0）: グリフのみでも幅正・高さ 22 以下。
  func testQuietStateFitsMenuBar() {
    let size = fittingSize(store: AttentionStore(), phase: .closed)
    XCTAssertGreaterThan(size.width, 0)
    XCTAssertLessThanOrEqual(size.height, 22)
  }

  /// ③ 収縮ピル（◐＋件数）: 高さ 22 以下・グリフ単体より幅が広い。
  func testCountPillFitsMenuBar() {
    let store = AttentionStore()
    store.apply(rows: [row(state: "waiting"), row(state: "done")])
    let size = fittingSize(store: store, phase: .closed)
    XCTAssertGreaterThan(size.width, fittingSize(store: AttentionStore(), phase: .closed).width)
    XCTAssertLessThanOrEqual(size.height, 22)
  }

  /// transient を 1 件載せた store。②が指す行は**一覧にも居る**——`apply(rows:)` がその行を
  /// 見失えば②はその場で取り下げられるので、行を入れた後の `count` は必ず 1 以上になる。
  /// （`noteTransient` は report 経路が即座に立て、一覧が追いつくのは次の chrome coalesce なので、
  /// その間だけは「②生存・件数 0」が実際に起きる。それは事故ではなく `arrivedCount` を見せる
  /// 理由そのもので、画は `menubar_arrival_first` が持つ。ここで測りたいのは追いついた後の姿。）
  /// 件数を欠いた構成で測ると幅の契約が実物より狭く出るので、必ず一覧を先に入れる。
  private func transientStore(workspace: String, message: String) -> AttentionStore {
    let store = AttentionStore()
    let row = AttentionRow(
      tabId: 1, workspaceName: workspace, tabTitle: "tab", state: "waiting", message: message,
      stateChangedAt: Date())
    store.apply(rows: [row])
    store.noteTransient(row, dwell: anyDwell)
    return store
  }

  /// 提案幅 `proposedWidth` を与えたときにレイアウトが取る幅。`fittingSize` は理想値の総和で、
  /// レイアウトが提案幅にどう反応するかを写さない——短い内容で膨らむ破れはここでしか捕まらない。
  private func renderedWidth(store: AttentionStore, proposedWidth: CGFloat) -> CGFloat {
    NSHostingController(
      rootView: MenuBarStatusView(store: store, ui: MenuBarUIState(), phase: .open)
    )
    .sizeThatFits(in: NSSize(width: proposedWidth, height: 40)).width
  }

  /// ② 滲み出しピル（WS 名＋文言）: 高さ 22 以下。静的状態（①③）より確実に広い
  /// ＝transient 出現で幅が伸びる契約（実機で伸びなかった回帰の再発防止）。
  /// 幅の上限は `testTransientPillCapsOverallWidth` が単独で持つ。
  func testTransientPillFitsMenuBarAndExpands() {
    let store = AttentionStore()
    let long = String(repeating: "とても長い文言 ", count: 40)
    store.apply(rows: [row(state: "waiting"), row(state: "done")])
    store.noteTransient(row(state: "waiting", message: long), dwell: anyDwell)
    let size = fittingSize(store: store, phase: .open)
    XCTAssertLessThanOrEqual(size.height, 22)

    let quietWidth = fittingSize(store: AttentionStore(), phase: .closed).width
    let countStore = AttentionStore()
    countStore.apply(rows: [row(state: "waiting"), row(state: "done")])
    let countWidth = fittingSize(store: countStore, phase: .closed).width
    XCTAssertGreaterThan(size.width, countWidth, "transient は収縮ピル（③）より広く滲み出る")
    XCTAssertGreaterThan(size.width, quietWidth, "transient は静的グリフ（①）より広く滲み出る")
  }

  /// 長い WS 名＋長文でもピル全体が幅上限を超えない（メニューバーの他アイテムを圧迫しない）。
  /// 件数スロットを**立てた**構成で測る——一覧を先に入れて `arrivedCount` を 1 以上に焼く。
  /// 件数が無い②は本番で起こり得ないうえ、そのぶん（間隔＋スロット上限）狭いところで頭打ちに
  /// なるので、`textBudget` の導出がずれても上限に触れず素通りしてしまう。
  func testTransientPillCapsOverallWidth() {
    let store = AttentionStore()
    let longRow = AttentionRow(
      tabId: 1, workspaceName: String(repeating: "workspace-name-", count: 10),
      tabTitle: "tab", state: "waiting",
      message: String(repeating: "とても長い文言 ", count: 40), stateChangedAt: Date())
    store.apply(rows: [longRow])
    store.noteTransient(longRow, dwell: anyDwell)
    let size = fittingSize(store: store, phase: .open)
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
        renderedWidth(store: store, proposedWidth: 500),
        fittingSize(store: store, phase: .open).width,
        accuracy: 2, "ws=\(ws) message=\(message): 広い提案でも内容幅へハグする")
    }
  }

  /// WS 名が短いぶんの幅は本文が吸う。本文が長ければ、WS 名の長短にかかわらずピルは
  /// 予算を使い切る＝同じ幅になる（WS 名が短いときだけピルが痩せる＝文言を出し切れて
  /// いない、ということが起きない）。
  ///
  /// 許容は本文フォント 1 文字ぶん。本文は与えられた予算ちょうどでは切れず**字形の境界まで**
  /// しか伸びないので、WS 名の長短で余る端数が変わる。破れ（本文が slack を吸わない）は WS 名
  /// 2 つの差＝100pt 超で出るため、1 文字の緩みでも取り逃さない。
  func testTransientPillGivesSpareWidthToMessage() {
    XCTAssertEqual(
      fittingSize(store: transientStore(workspace: shortWS, message: longMessage), phase: .open)
        .width,
      fittingSize(store: transientStore(workspace: longWS, message: longMessage), phase: .open)
        .width,
      accuracy: 12, "長い本文では WS 名の長短によらず予算を使い切る")
  }

  /// WS 名スロットは上限の範囲で**内容へハグする**。同じ本文なら、WS 名が短いピルは長い
  /// ピルより総幅が小さい。スロットが内容と無関係に上限いっぱいを取る実装（＝WS 名の右に
  /// 空白が出る、報告された不具合そのもの）だと両者が同じ総幅になるので、この不等号で落ちる。
  ///
  /// 本文は短い方を使う——長文だと双方が予算を使い切って総幅が並び、WS 名スロットの差が
  /// 総幅に現れない。
  func testTransientPillWorkspaceSlotHugsName() {
    XCTAssertLessThan(
      fittingSize(store: transientStore(workspace: shortWS, message: shortMessage), phase: .open)
        .width,
      fittingSize(store: transientStore(workspace: longWS, message: shortMessage), phase: .open)
        .width,
      "WS 名が短ければピルはそのぶん狭い（スロットが上限いっぱいを取らない）")
  }

  /// 本文スロットも**内容へハグする**＝短い本文で残り予算を吸い切らない。
  ///
  /// 上界 250 の根拠: 本文が内容で止まる限り、ピルは「固定部（◐ 15＋状態グリフ 11＋spacing
  /// 6×3＋padding 7×2＋外側 hair 2×2＝62）＋上限で頭打ちの WS 名スロット（≤120）＋短い本文」
  /// までしか伸びない＝約 200。250 はそこへ文言差・サブピクセル分の余裕を足した値で、
  /// 一方「本文が残り予算を吸い切る」破れは WS 名の長短によらず必ず上限 334
  /// （`transientMaxWidth` ＋ hair×2）へ張り付くため、その間で確実に切り分けられる。
  func testTransientPillShrinksForShortMessage() {
    for ws in [shortWS, longWS] {
      XCTAssertLessThan(
        fittingSize(store: transientStore(workspace: ws, message: shortMessage), phase: .open)
          .width, 250,
        "ws=\(ws): 短い本文では残り予算を吸わずピルが縮む")
    }
  }

  /// `PillRow` は**申告どおりに配置する**——`sizeThatFits` が返す幅と `placeSubviews` が実際に
  /// 使い切る幅（最終スロットの右端）が一致する。ずれた差分はそのままピル右端の死んだ空白に
  /// なる（gap を 1 個多く数えれば全②ピルが内容より spacing ぶん太る＝今回直した不具合の縮小版）。
  ///
  /// これは総幅の上界では捕まらない。上界は `transientMaxWidth` からの導出値で、そこまでの
  /// 遊びに数 pt の膨らみが埋もれるため。レイアウトの自己整合性としてここで直接固定する
  /// （上界を実測値へ寄せて代用すると、fixture の文言を変えるたびに落ちる脆いテストになる）。
  ///
  /// 予算に余る場合（切り詰めなし）と足りない場合（切り詰めあり）の両方で見る。
  func testPillRowPlacesExactlyWhatItDeclares() {
    for (budget, fold, label) in [
      (CGFloat(400), 1.0, "予算に余る"), (CGFloat(120), 1.0, "予算が足りない"),
      (CGFloat(400), 0.5, "中間スロットが畳まれかけ"), (CGFloat(400), 0.0, "中間スロットが畳み切り"),
    ] {
      let placed = PlacementBox()
      let host = NSHostingView(
        rootView: PillRow(spacing: 6, budget: budget) {
          // 畳むのは**先頭以外**のスロット。先頭は `measure` が gap を 0 に固定するので、
          // ここに置くと「間隔ごと畳む」（`gaps[index] * fold`）を一度も踏めない。
          slotProbe(ideal: 40)
          slotProbe(ideal: 60).pillSlot(gap: 6, fold: fold)
          PlacementProbe(box: placed) { slotProbe(ideal: 200) }
        })
      let declared = host.fittingSize
      host.frame = NSRect(origin: .zero, size: declared)
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(
        placed.maxX, declared.width, accuracy: 0.5,
        "\(label): 申告した幅と最終スロットの右端が一致する（右端に空白を作らない）")
    }
  }

  /// 幅は位相の**連続かつ狭義単調増加**な関数である＝①③↔②の境界で幅が飛ばない。
  /// 高さはどの位相でも 22 以下。
  /// 展開（`closing: false`）と収縮（`closing: true`）は別の曲線を描くので、両方で見る。
  func testWidthGrowsStrictlyWithOpenness() {
    let store = AttentionStore()
    store.apply(rows: [row(state: "waiting"), row(tabId: 2, state: "done")])
    store.noteTransient(row(state: "waiting", message: longMessage), dwell: anyDwell)
    for closing in [false, true] {
      var previous: CGFloat = 0
      for openness in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let phase = MenuBarArrival.Phase(openness: openness, gloss: nil, closing: closing)
        let size = fittingSize(store: store, phase: phase)
        XCTAssertGreaterThan(
          size.width, previous, "closing=\(closing) openness=\(openness): 幅は開くほど広い")
        XCTAssertLessThanOrEqual(size.height, 22, "closing=\(closing) openness=\(openness)")
        previous = size.width
      }
    }
  }

  /// **文言表示中は件数を出さない**（開き切りでは件数が幅に一切効かない）。
  /// **閉じた姿は実件数を示す**（閉じ切りでは件数の桁が幅に出る）。
  ///
  /// 文言の長短を問わず成立する。`PillRow` の予約は上限（`countCap`）ぶんの固定量なので、
  /// 桁が変わっても前の文言スロットの取り分が動かない——**切り詰めが起きる長文でこそ効く**
  /// （自然幅で予約していた頃は、ここで桁差がそのまま総幅に出ていた）。
  func testCountLeavesWidthUntouchedWhileOpen() {
    func width(phase: MenuBarArrival.Phase, count: Int, message: String) -> CGFloat {
      let store = AttentionStore()
      let rows = (1...count).map { row(tabId: $0, state: "waiting") }
      store.apply(rows: rows)
      store.noteTransient(row(state: "waiting", message: message), dwell: anyDwell)
      return fittingSize(store: store, phase: phase).width
    }
    for (label, message) in [("短文", shortMessage), ("長文（切り詰めあり）", longMessage)] {
      XCTAssertEqual(
        width(phase: .open, count: 2, message: message),
        width(phase: .open, count: 99, message: message), accuracy: 0.5,
        "\(label): 開き切りでは件数の桁が幅に出ない")
      XCTAssertLessThan(
        width(phase: .closed, count: 2, message: message),
        width(phase: .closed, count: 99, message: message),
        "\(label): 閉じ切りでは件数の桁がそのまま幅になる")
    }
  }

  /// 件数が変わるのは**収縮と同時**。開いている間は到来した瞬間の件数を保つので、報告の
  /// coalesce が展開の途中で一覧を増やしても姿は動かない（0 件からの到来で数字が閃かない）。
  /// 収縮に入った向きでは実件数を描く＝原典の「閉じながら『1』が生まれる」。
  func testOpeningHoldsArrivalCountAndCollapseShowsLiveCount() {
    let arriving = row(state: "waiting", message: shortMessage)
    /// 一覧が到来に追いついた store と、まだ追いついていない store。
    let live = AttentionStore()
    live.noteTransient(arriving, dwell: anyDwell)
    live.apply(rows: [arriving])
    let pending = AttentionStore()
    pending.noteTransient(arriving, dwell: anyDwell)

    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(pending.count, 0)
    XCTAssertEqual(
      fittingSize(store: live, phase: .open).width,
      fittingSize(store: pending, phase: .open).width, accuracy: 0.5,
      "展開中は一覧が増えても姿が動かない（数字が閃かない）")

    let collapsing = MenuBarArrival.Phase(openness: 0.02, gloss: nil, closing: true)
    XCTAssertGreaterThan(
      fittingSize(store: live, phase: collapsing).width,
      fittingSize(store: pending, phase: collapsing).width,
      "収縮側では実件数が現れる")
  }

  /// 閉じ切った②は③と**同じ幅**——畳まれたスロットは自分の直前の間隔ごと消えるので、
  /// 文言 3 スロットの gap が残らない。これが「①③↔②の境界で幅が飛ばない」の実体で、
  /// 単調性テストは相対比較なので固定オフセットを見逃す（ここは厳密な等式で押さえる）。
  func testClosedTransientHasSameWidthAsCountPill() {
    let rows = [row(state: "waiting"), row(tabId: 2, state: "done")]
    let bare = AttentionStore()
    bare.apply(rows: rows)
    let withTransient = AttentionStore()
    withTransient.apply(rows: rows)
    withTransient.noteTransient(row(state: "waiting", message: longMessage), dwell: anyDwell)
    XCTAssertEqual(
      fittingSize(store: withTransient, phase: .closed).width,
      fittingSize(store: bare, phase: .closed).width, accuracy: 0.5)
  }

  /// ①は地も水平余白も持たない（メニューバーの常態で 14pt を占有しない）＝◐ と hair だけ。
  func testQuietStateHasNoGroundPadding() {
    XCTAssertEqual(
      fittingSize(store: AttentionStore(), phase: .closed).width, 15 + Theme.Space.hair * 2,
      accuracy: 0.5)
  }

}

/// 提案幅 w に対して常に min(w, ideal) を取るスロット代用。文字送りに依存せず
/// 「切り詰めなし／あり」を厳密な数値で作れる（Text だと glyph 境界の端数が混ざる）。
private func slotProbe(ideal: CGFloat) -> some View {
  Color.clear.frame(
    minWidth: 0, idealWidth: ideal, maxWidth: ideal,
    minHeight: 0, idealHeight: 10, maxHeight: 10)
}

private final class PlacementBox: @unchecked Sendable { var maxX: CGFloat = -1 }

/// 自分が配置された bounds を記録するだけの Layout。計装はテスト側に閉じており、
/// プロダクション（`PillRow`）は無改造のまま実配置を外から観測できる。
private struct PlacementProbe: Layout {
  let box: PlacementBox

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    box.maxX = bounds.maxX
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
  }
}

private let shortWS = "orbe"
private let longWS = "very-long-workspace-name-here-xxx"
private let shortMessage = "完了"
private let longMessage = "Bash の許可が必要です — bin/rails db:migrate（スキーマに 2 テーブル追加）"
