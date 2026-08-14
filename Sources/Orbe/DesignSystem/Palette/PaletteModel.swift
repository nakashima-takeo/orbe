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
    /// 行末に出す表示専用バッジ（作成導線の `⌘N` 等）。`createStyle` の行でだけ描かれる。nil で出さない。
    var trailingBadge: String?
    /// 作成導線の行スタイル（accent 文字＋破線罫線＋右端バッジ）。表示専用（キー挙動は載せない）。
    var createStyle = false
    /// 汎用 `PaletteRow` の代わりに `SelectableRow` 上へ直接描く専用行コンテンツ（WS切替行）。nil で `PaletteRow`。
    var customContent: AnyView?
  }

  var rows: [RowItem] = []

  /// 「今この 1 行で起きている一時的なこと」を描く付属ビュー（通知音の試聴 EQ）。
  /// 行の意味（ラベル・`●`・継承）は `RowItem` が持ち、こちらは行の再構築なしで点いて消える
  /// ——↑↓ とホバーのたびに 13 行を組み直さずに装飾だけを動かすため。1 行だけであることは型が保証する。
  struct RowAccessory {
    var row: Int
    var view: AnyView
  }

  /// 付属ビューを出す 1 行。nil で出さない＝opt-in（`headerPills` / `hintKeys` と同じ規律）。
  /// `normal` / `dormant` の行でだけ描かれる（`customContent` の行には乗らない）。
  /// `row` は `rows` の添字なので、行を組み直す側が畳む。
  var rowAccessory: RowAccessory?

  /// 選択とホバー追従ガード（`ModalSelection` が代入経路のガードを一手に握る）。
  private var selection = ModalSelection()

  /// 選択行。ホバー追従以外の代入はモダリティを `.keyboard` へ戻す（→ `ModalSelection`）。
  var selected: Int {
    get { selection.index }
    set {
      let previous = selection.index
      selection.index = newValue
      if newValue != previous { onSelectionChanged?(newValue) }
    }
  }

  /// 選択行が**ユーザの操作で実際に動いた**ときの通知（設定パレットの通知音プレビューが購読する）。
  /// キー移動・タップ・ホバー追従だけが通り、`place` と `restoreSelection` は通らない
  /// ——面の組み立てや裏の再取得での追い直しはユーザの意図ではないため。
  var onSelectionChanged: ((Int) -> Void)?

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  /// ホバー開始による選択追従（`.pointer` のときだけ効く）。
  func hoverSelect(_ i: Int) {
    let previous = selection.index
    selection.hoverSelect(i)
    if selection.index != previous { onSelectionChanged?(selection.index) }
  }
  /// 面の組み立てによる選択の配置（モード遷移の初期選択・行差し替え後の収め直し）。
  /// 開いた直後の初期選択を hover に奪われないようモダリティは `.keyboard` へ戻すが、ユーザが
  /// 選んだのではないので `onSelectionChanged` は通さない（→ `restoreSelection` と同じ理由）。
  func place(_ i: Int) { selection.index = i }
  /// 裏の再取得で行がずれたときの選択の追い直し。ユーザの意図ではないのでモダリティを奪わない
  /// （→ `ModalSelection.restore`）。`selected` の setter で代入すると `.keyboard` へ戻り、
  /// ポインタ操作中の追従が切れる。
  func restoreSelection(_ i: Int) { selection.restore(i) }
  /// ヘッダ左のテキスト（サブメニューの「‹ 親」等）。nil で非表示。入力欄も無ければヘッダ行ごと描かれない。
  var breadcrumb: String?
  /// ヘッダ右端の表示専用ピル 1 件。**`ForEach` へ値で渡すために `Identifiable`** にしてある
  /// ——view からこの配列へ添字で読み返すと、配列が空へ縮む更新パスで SwiftUI が古い添字のまま
  /// 消えゆく子を評価し、範囲外アクセスでプロセスごと落ちる。`id` は `label`
  /// （同一セット内で `label` が一意であることがこの型の前提）。
  struct HeaderPill: Identifiable {
    var label: String
    var id: String { label }
  }

  /// ヘッダ右端の表示専用ピル（Attention の `⌘⌘` バッジ）。空で出さない＝opt-in（`hintKeys` と同じ規律）。
  var headerPills: [HeaderPill] = []

  /// リスト直上の全幅セグメント 1 枚（通知音サブパレットの試聴対象「完了 | 入力待ち」）。
  /// `HeaderPill` と同じ理由で `Identifiable`・`id` は `label`（`active` が反転しても identity が
  /// 変わらず `Text` が再マウントされない）。
  /// `glyph` を view でなくデータで持つのは、寸法と状態色の解決を DS 側に残すため。
  struct Segment: Identifiable {
    var label: String
    var glyph: AgentStateIcon.Kind?
    var active: Bool
    var id: String { label }
  }

  /// リスト直上の全幅セグメント。空で出さない＝opt-in（`headerPills` と同じ規律）。
  var segments: [Segment] = []
  /// セグメントのクリック（index）。パレットモデルが切替に結ぶ。
  var onTapSegment: (Int) -> Void = { _ in }

  /// リスト直上の一文（`segments` があればその下）。面の前提を言い切る補足。空で出さない＝opt-in。
  var caption = ""
  var hint = ""

  /// フッターヒントのキー付きセグメント 1 件（`HeaderPill` と同じ理由で `Identifiable`・`id` は `key`）。
  struct HintKey: Identifiable {
    var key: String
    var label: String
    var id: String { key }
  }

  /// フッターヒントのキー付きセグメント（key=副色・label=muted・デザイン第10シーン）。
  /// 空なら `hint` の素文字列を muted 一色で描く（既存パレットは無影響）。
  var hintKeys: [HintKey] = []
  /// カード面の濃度（GlassLevel）。既定は panel（α.72）。Attention は popup（α.90＝デザイン第10シーン
  /// rgba(panel, 0.9)）。幾何（radius 16）・blur（24）・枠（.08/.12）・影は面によらず panel 級で固定。
  var surface: Theme.GlassLevel = .panel
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
  /// focus トリガ。`focus()` だけが進め、SwiftUI が監視して `@FocusState` を立てる。
  private(set) var focusToken = 0

  /// focus の宛先を現在のモードへ確定させる `focusToken` の唯一の書き手。提示・モード遷移・
  /// **カード内のクリック**が共にここを通る（クリックが焦点を落とす機序は `PaletteCard` の
  /// `simultaneousGesture` 参照）。
  func focus() { focusToken &+= 1 }

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
  /// ⇥ の意味。true を返すとキーを消費（通知音サブパレットの試聴対象の反転）。既定は非消費＝
  /// 他パレットは従来どおり ⇥ に反応しない。
  var onTab: () -> Bool = { false }

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

  /// rows 差し替え後に選択を範囲内へ収める（ユーザ操作ではないので `place` 経由）。
  func clampSelection() {
    if selected >= rows.count { place(max(0, rows.count - 1)) }
  }
}
