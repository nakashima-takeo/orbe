import SwiftUI

/// オーバーレイ・パレットの汎用表示状態（@Observable）。モードや絞り込みの「意味」は持たず、
/// 行・選択・パンくず・ヒントという描画状態と、キー意図のコールバックだけを持つ。
/// 意味（mode/entries/activate/drillIn/goBack）は各パレットモデルが駆動して立て下げる。
@Observable final class PaletteModel {
  /// 描画用の 1 行。enabled=false は情報行（選択・実行の対象にしない）、dimmed は休眠（減光）。
  struct RowItem {
    var label: String
    var chevron = false
    var enabled = true
    var dimmed = false
    /// 設定パレット workspace スコープで、この行が global 継承中（未上書き）か。表示上の区別に使う。
    var inherited = false
    /// 行頭に置く付属ビュー（状態アイコンのプレビューグリフ等）。nil で出さない＝既存行は従来通り。
    var leading: AnyView?
    /// ラベルの後に muted で出す補足（workspace 行のディレクトリ等）。nil で出さない。
    var detail: String?
    /// 行末に出す表示専用バッジ（作成導線の `⌘N` 等）。nil で出さない。
    var trailingBadge: String?
    /// 作成導線の行スタイル（accent 文字＋破線罫線＋右端バッジ）。表示専用（キー挙動は載せない）。
    var createStyle = false
    /// 汎用 `PaletteRow` の代わりに `SelectableRow` 上へ直接描く専用行コンテンツ（WS切替行）。nil で `PaletteRow`。
    var customContent: AnyView?
  }

  var rows: [RowItem] = []

  /// 選択とホバー追従ガード（`ModalSelection` が代入経路のガードを一手に握る）。
  private var selection = ModalSelection()

  /// 選択行。ホバー追従以外の代入はモダリティを `.keyboard` へ戻す（→ `ModalSelection`）。
  var selected: Int {
    get { selection.index }
    set { selection.index = newValue }
  }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  /// ホバー開始による選択追従（`.pointer` のときだけ効く）。
  func hoverSelect(_ i: Int) { selection.hoverSelect(i) }
  /// ヘッダ左のテキスト（サブメニューの「‹ 親」等）。nil で非表示。入力欄も無ければヘッダ行ごと描かれない。
  var breadcrumb: String?
  /// ヘッダ右端の表示専用バッジ（Attention の `⌘⌘` 等）。nil で出さない（既存パレットは無影響）。
  var headerBadge: String?
  var hint = ""
  /// 背後の暗幕の強さ。workspace は normal、設定等の強いパレットは strong。
  var scrimStrength: Scrim.Strength = .strong

  /// 絞り込み入力欄（SwiftUI `TextField`）を出すか（フィルタを持つパレットのみ）。
  var fieldVisible = false
  /// 入力欄が filter（絞り込み専用）か editor（カーソル移動の要る本物の編集）か。
  /// filter ではカーソル移動がほぼ不要なため `←` を `onLeft`（戻る）へ回す。editor（改名）は false で
  /// `←` をカーソル移動に残す。`fieldVisible` のときのみ意味を持つ。
  var fieldIsFilter = false
  /// 絞り込み値（filtering の SSOT）。入力欄と双方向バインドする。
  var query = ""
  /// 絞り込み入力欄の placeholder。
  var placeholder = ""
  /// focus トリガ。提示元（パレットモデル）がインクリメントし、SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0

  /// 行タップ（index）。パレットモデルが選択＋実行に結ぶ。
  var onTapRow: (Int) -> Void = { _ in }
  /// カード外（scrim）タップ。パレットモデルが閉じる。
  var onScrimTap: () -> Void = {}
  /// 絞り込み値が変わった（入力欄から）。パレットモデルが再構築に結ぶ。
  var onQueryChange: () -> Void = {}

  // MARK: - キー意図（パレットモデルが mode に応じて配線する）
  var onUp: () -> Void = {}
  var onDown: () -> Void = {}
  var onJumpTop: () -> Void = {}
  var onJumpBottom: () -> Void = {}
  var onActivate: () -> Void = {}
  /// ← ＝戻る。入力欄なしモード（詳細メニュー・AgentPalette）と、filter 入力欄（`fieldIsFilter`）で届く。
  /// editor 入力欄（改名）の ← は入力欄のカーソル移動になり、ここへは来ない（戻るは Esc）。
  var onLeft: () -> Void = {}
  /// → の意味。true を返すとキーを消費（ドリルイン）、false でカーソル移動に委ねる（改名）。
  var onRight: () -> Bool = { false }
  var onEscape: () -> Void = {}
  /// delete＝設定パレット root で workspace 上書きを解除（global 継承へ戻す）。入力欄なしモードのみ届く。
  var onDelete: () -> Void = {}

  /// enabled な行だけを巡る選択移動（情報行は飛ばす）。
  func move(_ d: Int) {
    guard rows.contains(where: { $0.enabled }) else { return }
    var i = selected
    repeat { i = (i + d + rows.count) % rows.count } while !rows[i].enabled
    selected = i
  }

  /// enabled な先頭/末尾行へ選択をジャンプ（d<0=先頭・d>=0=末尾。有効行ゼロ/空は no-op）。
  func jump(_ d: Int) {
    let i = d < 0 ? rows.firstIndex(where: { $0.enabled }) : rows.lastIndex(where: { $0.enabled })
    guard let i else { return }
    selected = i
  }

  /// rows 差し替え後に選択を範囲内へ収める。
  func clampSelection() {
    if selected >= rows.count { selected = max(0, rows.count - 1) }
  }
}
