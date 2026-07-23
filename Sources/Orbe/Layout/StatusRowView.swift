import AppKit
import SwiftUI

/// chrome 全体の寸法トークン（TopBar 28＋TabBar 28 の 2 段）。散在させず一箇所で持つ。
enum Chrome {
  // 上段（TopBar）。標準タイトルバー高に合わせ、信号機を帯の縦中央へ置いて上下余白を対称化する。
  static let headerHeight: CGFloat = 28
  static let tabRowHeight: CGFloat = 28  // 下段（セグメント形タブ行）
  static let barHeight: CGFloat = headerHeight + tabRowHeight
  static let railWidth: CGFloat = 32  // EditorPane 常駐レール（本体を閉じたときの facade 幅）
  static let leftColumn: CGFloat = 80  // 信号機ボタンを避ける左の柱
  static let edgePad: CGFloat = 16  // TopBar の左右余白
  static let tabRowPad: CGFloat = 3  // タブ行の内側余白（上下左右）
  static let tabHeight: CGFloat = tabRowHeight - tabRowPad * 2  // セグメント高（行 fill）
  static let tabGap: CGFloat = 2  // セグメント間
  static let tabMaxWidth: CGFloat = 140  // セグメント 1 本の上限。超える名前は省略記号で切り詰め
  // shrink-to-fit の下限。数文字＋省略記号が読める幅。これ以上は縮めず横スクロールへ回す。
  static let tabMinWidth: CGFloat = 40
  // インライン改名の編集タブの下限幅（数語を打てる幅）。shrink 床（40）だと打てないため View 側で上書きする。
  static let tabEditFloor: CGFloat = 120
}

/// 最上段 chrome（StatusRow）の状態。WindowController が `update` で流し込み、
/// SwiftUI `StatusRowView` が描く。信号機ボタンの縦位置（system furniture）もここへ集める。
@Observable final class StatusRowModel {
  var workspace = ""
  var titles: [String] = []
  /// 各タブの集約状態種別（nil で表示なし＝idle/無し）。詳細＋件数は上段右端の rollup 側に出す。
  var glyphs: [AgentStateIcon.Kind?] = []
  var active = 0
  /// `~` 短縮済みのアクティブペイン cwd。
  var cwd: String?
  /// 全 workspace 横断のエージェント状態ロールアップ（状態順の `[(state, count)]`）。
  var rollup: [(state: String, count: Int)] = []
  /// 検証インスタンス限定の build-id（`ORBE_STATE_DIR` 設定時のみ）。本物では nil。
  let buildId: String?

  var onSelect: (Int) -> Void = { _ in }
  var onNewTab: () -> Void = {}
  /// 右端の件数ストリップのクリック（Attention パレットを開く）。
  var onAttentionTap: () -> Void = {}
  /// タブを `from` から挿入先 index `to`（0…count）へ並び替える（同一 workspace 内・commit-on-drop）。
  var onReorder: (Int, Int) -> Void = { _, _ in }

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
    let titles: [String]
    let glyphs: [AgentStateIcon.Kind?]
    let active: Int
    let cwd: String?
    let rollup: [(state: String, count: Int)]
  }

  func update(_ s: Snapshot) {
    workspace = s.workspace
    titles = s.titles
    glyphs = s.glyphs
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

/// shrink-to-fit の幅計算（純関数・単体テスト可能）。自然幅を maxWidth で cap し、収まればそのまま、
/// 溢れれば CSS flex shrink と同じく**自然幅に比例して縮め、minWidth の床に達したタブは凍結して
/// 残りへ再配分**する（min-width 0 まで潰さず床 40 を設けている。可読性のための設計判断・
/// `docs/design-system.md` §9）。
/// 全タブが床でも溢れる時だけ合計が available を超え横スクロールへ。
enum StatusTabLayout {
  /// 各タブへ与える幅（寸法は `Chrome` の定数を使う）。`naturals` と同じ要素数。
  static func widths(naturals: [CGFloat], available: CGFloat) -> [CGFloat] {
    let capped = naturals.map { min($0, Chrome.tabMaxWidth) }
    let n = CGFloat(capped.count)
    guard n > 0 else { return [] }
    let gaps = Chrome.tabGap * n  // 要素は n タブ + ＋ボタンで計 n+1、その間の隙間は n 個
    let room = available - gaps - Chrome.tabHeight  // ＋ボタンは tabHeight 角
    if capped.reduce(0, +) <= room { return capped }

    var result = capped
    var frozen = [Bool](repeating: false, count: capped.count)
    while true {
      let flexTotal = zip(capped, frozen).filter { !$0.1 }.map(\.0).reduce(0, +)
      let frozenTotal = zip(result, frozen).filter { $0.1 }.map(\.0).reduce(0, +)
      let target = room - frozenTotal
      guard flexTotal > 0 else { break }
      let scale = target / flexTotal
      var changed = false
      for i in result.indices where !frozen[i] {
        let w = capped[i] * scale
        if w < Chrome.tabMinWidth {
          result[i] = Chrome.tabMinWidth
          frozen[i] = true
          changed = true
        } else {
          result[i] = w
        }
      }
      if !changed { break }
    }
    return result
  }
}

/// 最上段 chrome をネイティブ SwiftUI で描く（TopBar＋TabBar・§5.1）。
/// 上段=現在地（workspace 名・build-id・cwd、左）とステータスストリップ（右端）、テキストは信号機の
/// 縦中央へ整列・背景は透明（最背面の BackgroundGlow が見える）。下段=全幅セグメント形タブ行
/// （地 tabRowBg・DSTab・shrink＋横スクロール・＋ボタン）。罫線は持たない（tabRowBg の濃度差が境界）。
/// 背景に窓ドラッグ（タブ/ボタンのクリックは奪わない）。
struct StatusRowView: View {
  @Bindable var model: StatusRowModel
  @Environment(\.chromeTranslucency) private var translucency
  @Environment(\.agentIconResolver) private var iconResolver
  // 寸法計算（StatusRowView+Metrics）が同じ resolver で幅を測るため internal。
  @Environment(\.chromeFontResolver) var fontResolver

  /// タップ（切替）と掴み（並び替え）を分ける最小移動量。閾値未満の操作は DSTab の tap が担う。
  /// 並び替えジェスチャは `StatusRowView+Reorder.swift`。
  let dragActivation: CGFloat = 6

  // ドラッグ並び替えの一時状態（掴み中のみ有効・onEnded でリセット）。commit-on-drop のためデータは触らない。
  @State var dragFrom: Int?  // 掴んでいるタブの実配列 index
  @State var dragTranslation: CGFloat = 0  // 掴み開始からの水平移動量
  @State var dropIndex: Int?  // 挿入先 index（0…count）
  // 掴み開始時のタブ幅を固定する（挿入先/キャレット計算の基準）。掴み中にグリフ出現等で live な幅が動いても
  // 基準がぶれず、確定ドロップが 1 個分ずれない。commit-on-drop のレイアウト凍結と整合。
  @State var dragWidths: [CGFloat] = []

  var body: some View {
    ZStack(alignment: .topLeading) {
      // 背景＝窓ドラッグ面。1クリックは window.performDrag で Window Server へ委譲（Space 切替等に参加）、
      // ダブルクリックは AppleActionOnDoubleClick を読んで zoom/miniaturize を明示実行（システム設定準拠）。
      // タブ/ボタンは前面で自前の tap を持つため、空き領域のドラッグ/ダブルクリックだけを拾う。
      WindowDragArea()
      VStack(spacing: 0) {
        topRow.frame(height: Chrome.headerHeight)
        bottomRow.frame(height: Chrome.tabRowHeight)
      }
    }
    // 透過時は端末と同濃度の veil を敷く（不透明時は clear＝最背面 BackgroundGlow の glow を透かす現行）。
    .background(translucency.additiveBase)
    .background(WindowAccessor(model: model))
  }

  // MARK: - 上段（TopBar）

  /// 上段テキストの縦中央を信号機ボタン中央へ寄せる量（slot 中央＝headerHeight/2 からのずれ）。
  /// ずれ幅が行高を食いうるため ±4 に clamp する。
  private var headerYShift: CGFloat {
    let shift = (model.closeCenterY ?? Chrome.headerHeight / 2) - Chrome.headerHeight / 2
    return min(max(shift, -4), 4)
  }

  // 左＝現在地（workspace 名→build-id→cwd の粗→細）、右端＝ステータスストリップ。中央は空（窓ドラッグ面）。
  // 幅が足りない時は cwd から縮む（workspace 名・build-id は layoutPriority、ストリップは fixedSize で保護）。
  private var topRow: some View {
    HStack(spacing: Theme.Space.beat) {
      fontResolver.text(model.workspace, base: Theme.Typography.chrome)
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .layoutPriority(1)
      if let buildId = model.buildId {
        Text(buildId)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .layoutPriority(1)
      }
      if let cwd = model.cwd, !cwd.isEmpty {
        fontResolver.text(cwd, base: Theme.Typography.meta)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.head)  // パスは末尾側を残す
      }

      Spacer(minLength: Theme.Space.beat)

      if !model.rollup.isEmpty {
        // クリックで Attention パレット。見た目は変えない（hover 装飾は足さない）。
        StatusRollupView(rollup: model.rollup)
          .fixedSize()
          .contentShape(Rectangle())
          .onTapGesture { model.onAttentionTap() }
      }
    }
    .padding(.leading, Chrome.leftColumn)
    .padding(.trailing, Chrome.edgePad)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .offset(y: headerYShift)
  }

  // MARK: - 下段（セグメント形タブ行・全幅）

  private var bottomRow: some View {
    tabStrip
      .padding(Chrome.tabRowPad)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // ShapeStyle 版 background は既定で safe area へ自動拡張する。実窓（fullSizeContentView）では
      // タイトルバー帯の safe area が行を貫くため、拡張を止めないと帯が TopBar まで覆う。
      .background(Color.theme.tabRowBg, ignoresSafeAreaEdges: [])
  }

  private var tabStrip: some View {
    GeometryReader { geo in
      let widths = tabWidths(available: geo.size.width)
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Chrome.tabGap) {
            ForEach(model.titles.indices, id: \.self) { i in
              let isEditing = model.editingIndex == i
              DSTab(
                title: displayTitle(i), active: i == model.active, stateGlyph: stateGlyph(i),
                stateSymbol: stateGlyph(i).flatMap { iconResolver.symbol(for: $0) },
                action: { model.onSelect(i) },
                editing: isEditing,
                editingText: $model.editingText,
                editFocusToken: model.editFocusToken,
                editPlaceholder: model.editingPlaceholder,
                onSubmit: { model.onCommitRename(model.editingText) },
                onCancel: { model.onCancelRename() }
              )
              .frame(width: widths.indices.contains(i) ? widths[i] : nil)
              // 掴んだタブは指に追従（slot は残す＝commit-on-drop）・前面へ・わずかに透かして浮きを示す。
              .offset(x: dragFrom == i ? dragTranslation : 0)
              .zIndex(dragFrom == i ? 1 : 0)
              .opacity(dragFrom == i ? 0.85 : 1)
              // 編集タブには drag を付けない（.subviews で TextField 操作は通し、掴み替えだけ止める）。
              .gesture(
                tabDragGesture(i: i, widths: widths), including: isEditing ? .subviews : .all
              )
              .id(i)
            }
            StatusPlusButton(action: model.onNewTab)
          }
          .frame(minWidth: geo.size.width, alignment: .leading)
          .frame(height: Chrome.tabHeight)
          // 挿入キャレット（離せばここに入る）。隣接タブはずらさない。
          .overlay(alignment: .leading) {
            if let j = dropIndex {
              Rectangle()
                .fill(Color.theme.accentPrimary)
                .frame(width: 2, height: Chrome.tabHeight)
                .offset(x: insertionCaretX(j, widths: dragWidths))
                .allowsHitTesting(false)
            }
          }
        }
        .onChange(of: model.active) { _, new in proxy.scrollTo(new, anchor: .center) }
        // 編集開始時、編集タブが横スクロール域外でも可視域へ入れる。
        .onChange(of: model.editingIndex) { _, new in
          if let n = new { proxy.scrollTo(n, anchor: .center) }
        }
        .onChange(of: model.titles.count) { _, _ in
          // 掴み中にタブ集合が変わったら（shell exit 等）掴み状態を破棄する。index が総崩れするため
          // 継続は不正、かつ onEnded は発火しないので、ここで解除しないと浮いたまま復帰しない。
          if dragFrom != nil {
            dragFrom = nil
            dragTranslation = 0
            dropIndex = nil
            dragWidths = []
          }
          proxy.scrollTo(model.active, anchor: .center)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: Chrome.tabHeight)
  }
}

/// 新規タブ用の「＋」。セグメント様式（地 tabSegBg・radius 3）・hover で淡い強調。
private struct StatusPlusButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Image(systemName: "plus")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(hovering ? Color.theme.textSecondary : Color.theme.textMuted)
      .frame(width: Chrome.tabHeight, height: Chrome.tabHeight)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.xs)
          .fill(Color.theme.tabSegBg)
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .onHover { hovering = $0 }
  }
}

/// 窓ドラッグ面（Ghostty `WindowDragView` 同型）。1クリックは `window.performDrag(with:)` で
/// Window Server へドラッグを委譲し（Space 切替・スナップ等に参加）、ダブルクリックは
/// `AppleActionOnDoubleClick`（システム設定）を読んで zoom / miniaturize を明示実行する。
/// 透明で、タブ/＋ は前面にあるため tap を奪わない。
private struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
      if event.type == .leftMouseDown, event.clickCount == 1 {
        window?.performDrag(with: event)
      } else if event.clickCount >= 2 {
        handleDoubleClick()
      } else {
        super.mouseDown(with: event)
      }
    }

    /// タイトルバーのダブルクリック挙動。システム設定 `AppleActionOnDoubleClick` 準拠。
    private func handleDoubleClick() {
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window?.miniaturize(nil)
      case "None": break
      default: window?.zoom(nil)  // Maximize もしくは未設定（既定の zoom）
      }
    }
  }
}

/// 信号機（close ボタン）の位置を読み、`StatusRowModel` へ反映する極小プローブ。
/// 位置は実窓にしか無い system furniture なので、ここだけ実窓を読む。
private struct WindowAccessor: NSViewRepresentable {
  let model: StatusRowModel
  func makeNSView(context: Context) -> NSView { WindowProbe(model: model) }
  func updateNSView(_ nsView: NSView, context: Context) { (nsView as? WindowProbe)?.sync() }
}

private final class WindowProbe: NSView {
  let model: StatusRowModel
  init(model: StatusRowModel) {
    self.model = model
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    sync()
  }
  override func layout() {
    super.layout()
    sync()
  }

  func sync() {
    let centerY = Self.closeCenterFromTop(in: window)
    // レイアウト経路から observable を直接触ると更新サイクルと衝突しうるため次の run loop へ逃がす。
    DispatchQueue.main.async { [model] in
      if model.closeCenterY != centerY { model.closeCenterY = centerY }
    }
  }

  /// close ボタン中央の、contentView 上端からの距離。chrome は contentView 上端に密着するので
  /// そのまま上段の縦整列に使える。信号機が無い（fullscreen 等）なら nil。
  private static func closeCenterFromTop(in window: NSWindow?) -> CGFloat? {
    guard let window, let content = window.contentView,
      let close = window.standardWindowButton(.closeButton), close.superview != nil
    else { return nil }
    let r = close.convert(close.bounds, to: content)
    return content.isFlipped ? r.midY : content.bounds.height - r.midY
  }
}
