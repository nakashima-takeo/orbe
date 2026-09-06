import SwiftUI

/// 最上段 chrome（StatusRow）の状態。WindowController が `update` で流し込み、
/// SwiftUI `StatusRowView` が描く。信号機ボタンの縦位置（system furniture）もここへ集める。
@Observable final class StatusRowModel {
  var workspace = ""
  /// タブ行（セル＋セグメント構造）。1 つの値として代入され、View はこれだけを辿る。
  var strip = TabStrip()
  var active = 0
  /// `~` 短縮済みのアクティブタブの cwd。
  var cwd: String?
  /// 全 workspace 横断のエージェント状態ロールアップ（状態順の `[(state, count)]`）。
  var rollup: [(state: String, count: Int)] = []
  /// 検証インスタンス限定の build-id（`ORBE_STATE_DIR` 設定時のみ）。本物では nil。
  let buildId: String?

  var onSelect: (Int) -> Void = { _ in }
  /// タブ `i` をタブごと閉じる（中クリック）。選択切替を挟まない。
  var onCloseTab: (Int) -> Void = { _ in }
  var onNewTab: () -> Void = {}
  /// 右端の件数ストリップのクリック（Attention パレットを開く）。
  var onAttentionTap: () -> Void = {}
  /// タブ `from` を挿入先 `to`（タブ index・0…count・**挿入前 index 基準**＝自分を抜く前の並びで数える）へ
  /// 並び替える（同一セグメント内・commit-on-drop）。
  var onReorder: (_ from: Int, _ to: Int) -> Void = { _, _ in }
  /// タブ `from` を含むセグメントを丸ごと、セグメント境界 `to`（タブ index・0…count・挿入前 index 基準）
  /// へ動かす。
  var onReorderSegment: (_ from: Int, _ to: Int) -> Void = { _, _ in }
  /// タブ `tabId`（位置 index ではない）のエージェント状態を idle へ落とす
  /// （コンテキストメニュー）。選択切替を挟まない。
  var onResetAgentState: (_ tabId: Int) -> Void = { _ in }

  // MARK: - インライン改名（Cmd+R）
  // これらは `update(Snapshot)` が touch しない別フィールドなので、flushChrome の snapshot 反映で
  // 編集状態は消えない（WindowController が beginTabRename/endTabRename で立て下げる）。
  /// 編集中タブの index（nil＝非編集）。
  var editingIndex: Int?
  /// 編集テキストの SSOT（TextField と双方向バインド）。
  var editingText: String = ""
  /// 空欄時に薄く見せる戻り先の派生タイトル（②③）。
  var editingPlaceholder: String = ""
  /// field editor へ first responder を移す focus 駆動トークン（提示元が `&+= 1`）。
  var editFocusToken: Int = 0
  /// 確定（trim 後の入力を渡す。空なら派生名へ戻す＝解除は WindowController 側で判断）。
  var onCommitRename: (String) -> Void = { _ in }
  /// 取消（Esc・blur・他所クリック）。
  var onCancelRename: () -> Void = {}

  /// 信号機（close ボタン）中央の chrome 上端からの距離。fullscreen 等で信号機が無いと nil。
  var closeCenterY: CGFloat?

  init() { buildId = Self.verificationBuildID() }

  /// chrome へ反映する 1 回ぶんのスナップショット。
  struct Snapshot {
    let workspace: String
    let strip: TabStrip
    let active: Int
    let cwd: String?
    let rollup: [(state: String, count: Int)]
  }

  func update(_ s: Snapshot) {
    workspace = s.workspace
    strip = s.strip
    active = s.active
    cwd = s.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
    rollup = s.rollup
  }

  /// 検証インスタンス（`ORBE_STATE_DIR` 非空）でだけ、`.app` に刻まれた build-id を返す。
  /// 本物の常用 Orbe（未設定）や build-id 未刻印（`swift run`）では nil。
  private static func verificationBuildID() -> String? {
    guard let dir = ProcessInfo.processInfo.environment["ORBE_STATE_DIR"], !dir.isEmpty
    else { return nil }
    guard let id = Bundle.main.object(forInfoDictionaryKey: "OrbeBuildID") as? String,
      !id.isEmpty
    else { return nil }
    return id
  }
}
