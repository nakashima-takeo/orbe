import SwiftUI

/// TopBar の現在地の断片。`dim` は cwd・根（`textMuted`）、`text` は根の下の相対パス・根の外の絶対パス
/// （`statusText`）。
struct LocationPart: Equatable {
  enum Tone: Equatable {
    case dim, text
  }
  let text: String
  let tone: Tone

  static func dim(_ text: String) -> LocationPart { LocationPart(text: text, tone: .dim) }
  static func text(_ text: String) -> LocationPart { LocationPart(text: text, tone: .text) }
}

/// 信号機（close ボタン）の chrome に対する置かれ方。実窓を読む probe（`AppShell` が付ける）が書く。
enum TrafficLights: Equatable {
  /// chrome の上に無い（ネイティブ・フルスクリーンで AppKit が上端の帯へ移した／窓にボタンが無い）。
  case absent
  /// chrome 上端から close ボタン中央までの距離。
  case over(centerY: CGFloat)

  /// 信号機が chrome の上にあるか。上段左の柱の在否はこれだけで決まり、`centerY` の揺れには反応しない。
  var isOverChrome: Bool {
    if case .over = self { return true }
    return false
  }
}

/// 最上段 chrome（StatusRow）の状態。WindowController が `update` で流し込み、
/// SwiftUI `StatusRowView` が描く。信号機の置かれ方（system furniture）もここへ集める。
@Observable final class StatusRowModel {
  var workspace = ""
  /// タブ行（セル＋セグメント構造）。1 つの値として代入され、View はこれだけを辿る。
  var strip = TabStrip()
  var active = 0
  /// 現在地（アクティブタブの焦点の面が居る場所）。`~` 短縮済みのトーン付き断片列。空は出さない。
  var location: [LocationPart] = []
  /// アクティブタブの位置ドット（エディター・端末）。0 タブは nil。
  var faceDots: FaceGeometry.FaceDots?
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

  /// 信号機の置かれ方。既定は「上段の縦中央にある（寄せ量 0）」姿——probe を持たない見本系
  /// （preview・gallery）と probe が読む前の初回描画を、柱の空いた姿で決定的に描くため。
  var trafficLights: TrafficLights = .over(centerY: Chrome.headerHeight / 2)

  init() { buildId = Self.verificationBuildID() }

  /// chrome へ反映する 1 回ぶんのスナップショット。
  struct Snapshot {
    let workspace: String
    let strip: TabStrip
    let active: Int
    let location: TerminalTab.Location?
    let faceDots: FaceGeometry.FaceDots?
    let rollup: [(state: String, count: Int)]
  }

  func update(_ s: Snapshot) {
    workspace = s.workspace
    strip = s.strip
    active = s.active
    location = s.location.map(Self.parts(of:)) ?? []
    faceDots = s.faceDots
    rollup = s.rollup
  }

  /// 事実 → 表現の写し（1 か所）。`~` 短縮は純粋なパス片（根・パス）にかけてから区切り `/` を足す
  /// （`abbreviatingWithTildeInPath` は末尾の `/` を落とす）。
  static func parts(of location: TerminalTab.Location) -> [LocationPart] {
    let short = { (path: String) in (path as NSString).abbreviatingWithTildeInPath }
    switch location {
    case .cwd(let path): return [.dim(short(path))]
    case .root(let root): return [.dim(short(root))]
    case .file(let root, let relative): return [.dim(short(root) + "/"), .text(relative)]
    case .absolute(let path): return [.text(short(path))]
    }
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
