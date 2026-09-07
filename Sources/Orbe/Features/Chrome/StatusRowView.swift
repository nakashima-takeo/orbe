import AppKit
import SwiftUI

/// chrome 全体の寸法トークン（TopBar 28＋TabBar 28 の 2 段）。散在させず一箇所で持つ。
enum Chrome {
  // 上段（TopBar）。標準タイトルバー高に合わせ、信号機を帯の縦中央へ置いて上下余白を対称化する。
  static let headerHeight: CGFloat = 28
  static let tabRowHeight: CGFloat = 28  // 下段（セグメント形タブ行）
  static let barHeight: CGFloat = headerHeight + tabRowHeight
  static let leftColumn: CGFloat = 80  // 信号機ボタンを避ける左の柱
  static let edgePad: CGFloat = 16  // TopBar の左右余白
  static let tabRowPad: CGFloat = 3  // タブ行の内側余白（上下左右）
  static let tabHeight: CGFloat = tabRowHeight - tabRowPad * 2  // セグメント高（行 fill）
  static let tabGap: CGFloat = 6  // セグメント間
  static let tabMaxWidth: CGFloat = 140  // セル 1 枚の上限。超える名前は省略記号で切り詰め
  // セル 1 枚の床。数文字＋省略記号が読める幅。短い名前でもこれを下回らず、shrink もここで止めて
  // 以降は横スクロールへ回す。
  static let tabMinWidth: CGFloat = 40
  // インライン改名の編集セルの下限幅（数語を打てる幅）。shrink 床（40）だと打てないため View 側で上書きする。
  static let tabEditFloor: CGFloat = 120
}

/// 最上段 chrome をネイティブ SwiftUI で描く（TopBar＋TabBar・§5.1）。
/// 上段=現在地（workspace 名・build-id・cwd、左）とステータスストリップ（右端）、テキストは信号機の
/// 縦中央へ整列・背景は透明（最背面の BackgroundGlow が見える）。下段=全幅セグメント形タブ行
/// （地 tabRowBg・同 worktree のタブを連ねた DSTabSegment・shrink＋横スクロール・＋ボタン）。
/// 罫線は持たない（tabRowBg の濃度差が境界）。背景に窓ドラッグ（タブ/ボタンのクリックは奪わない）。
struct StatusRowView: View {
  @Bindable var model: StatusRowModel
  @Environment(\.chromeTranslucency) private var translucency
  @Environment(\.agentIconResolver) private var iconResolver
  @Environment(\.localization) private var l10n
  // 寸法計算（StatusRowView+Metrics）が同じ resolver で幅を測るため internal。
  @Environment(\.chromeFontResolver) var fontResolver

  /// タップ（切替）と掴み（並び替え）を分ける最小移動量。閾値未満の操作は DSTab の tap が担う。
  /// 並び替えジェスチャは `StatusRowView+Reorder.swift`。
  let dragActivation: CGFloat = 6

  // ドラッグ並び替えの掴み状態（遷移は `DragState` に閉じる）。commit-on-drop のためデータは触らない。
  @State var dragState = DragState()
  private var drag: DragSession? { dragState.session }

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
      // 行の内側余白 3 は「ScrollView の外側 2 ＋ スクロール内容の内側 1」に割る。グループの枠は器の
      // 外側 1px なので、その帯をスクロール内容に含めないと ScrollView が枠の上下・行左端を切る。
      .padding(Chrome.tabRowPad - DSTabSegmentMetrics.frameOutset)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // ShapeStyle 版 background は既定で safe area へ自動拡張する。実窓（fullSizeContentView）では
      // タイトルバー帯の safe area が行を貫くため、拡張を止めないと帯が TopBar まで覆う。
      .background(Color.theme.tabRowBg, ignoresSafeAreaEdges: [])
  }

  /// セル・セグメント構造・幅はすべて 1 回の body 評価で読んだ `strip` から出す。入れ子 ForEach の
  /// 子は捕捉した値だけを辿り、model の配列を index で引かない（集合と構造が別々に更新される窓を持たない）。
  private var tabStrip: some View {
    GeometryReader { geo in
      let strip = model.strip
      let inset = DSTabSegmentMetrics.frameOutset
      let available = geo.size.width - inset * 2
      let widths = tabWidths(strip, available: available)
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Chrome.tabGap) {
            ForEach(strip.segments.indices, id: \.self) { s in
              let segment = strip.segments[s]
              let grabbed = drag.flatMap { $0.source == .segment(s) ? $0 : nil }
              DSTabSegment(
                kind: segment.isGroup
                  ? .group(colorIndex: segment.colorIndex) : .single
              ) {
                if segment.isGroup {
                  DSSegmentBar(colorIndex: segment.colorIndex)
                    .gesture(dragGesture(.segment(s), widths: widths, segments: strip.ranges))
                }
                ForEach(segment.cells) { cell in
                  // 2 枚以上の連ではセルを掴む。単独タブはセルがセグメントそのもの（境界へ落とす）。
                  tabCell(cell, divided: segment.isGroup, width: widths[cell.index])
                    .gesture(
                      dragGesture(
                        segment.isGroup ? .tab(cell.index) : .segment(s), widths: widths,
                        segments: strip.ranges),
                      including: model.editingIndex == cell.index ? .subviews : .all)
                }
              }
              // 掴んだセグメントは指に追従（slot は残す＝commit-on-drop）・前面へ・わずかに透かして浮きを示す。
              .offset(x: grabbed?.translation ?? 0)
              .zIndex(grabbed == nil ? 0 : 1)
              .opacity(grabbed == nil ? 1 : 0.85)
            }
            StatusPlusButton(action: model.onNewTab)
          }
          .frame(minWidth: available, alignment: .leading)
          .frame(height: Chrome.tabHeight)
          // 挿入キャレット（離せばここに入る）。隣接タブはずらさない。
          .overlay(alignment: .leading) {
            if let drag {
              Rectangle()
                .fill(Color.theme.accentBright)
                .frame(width: 2, height: Chrome.tabHeight)
                .offset(x: Self.insertionCaretX(drag))
                .allowsHitTesting(false)
            }
          }
          .padding(inset)
        }
        .onChange(of: model.active) { _, new in proxy.scrollTo(new, anchor: .center) }
        // 編集開始時、編集タブが横スクロール域外でも可視域へ入れる。
        .onChange(of: model.editingIndex) { _, new in
          if let n = new { proxy.scrollTo(n, anchor: .center) }
        }
        .onChange(of: model.strip.dragStructure) { _, _ in
          // 掴み中にタブ集合・順序・連構造が変わったら（shell exit・cd 再判定等）掴み状態を破棄する。
          // 凍結した幾何が実体とずれ、掴んでいた View は構造ごと消えて onEnded が来ない。
          dragState.discard()
          proxy.scrollTo(model.active, anchor: .center)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: Chrome.tabHeight + DSTabSegmentMetrics.frameOutset * 2)
  }

  /// セル 1 枚（DSTab）に app 層の配線（選択・中クリック・改名・コンテキストメニュー・掴み中の追従）を付ける。
  private func tabCell(_ cell: TabStrip.Cell, divided: Bool, width: CGFloat) -> some View {
    let i = cell.index
    // メニューが開いている間にタブ集合が変わっても、右クリックした時点のタブを指し続ける。
    let tabId = cell.tabId
    let isEditing = model.editingIndex == i
    let grabbed = drag.flatMap { $0.source == .tab(i) ? $0 : nil }
    return DSTab(
      title: displayTitle(cell), active: i == model.active, stateGlyph: cell.glyph,
      stateSymbol: cell.glyph.flatMap { iconResolver.symbol(for: $0) },
      action: { model.onSelect(i) },
      onMiddleClick: { model.onCloseTab(i) },
      divided: divided,
      editing: isEditing,
      editingText: $model.editingText,
      editFocusToken: model.editFocusToken,
      editPlaceholder: model.editingPlaceholder,
      onSubmit: { model.onCommitRename(model.editingText) },
      onCancel: { model.onCancelRename() }
    )
    .contextMenu {
      Button(l10n.string(.tabMenuResetAgentState)) {
        if let tabId { model.onResetAgentState(tabId) }
      }
      .disabled(cell.glyph == nil || tabId == nil)
    }
    .frame(width: width)
    // 掴んだセルは指に追従（セグメントの中に収める）・前面へ・わずかに透かして浮きを示す。
    .offset(x: grabbed.map(Self.cellOffset) ?? 0)
    .zIndex(grabbed == nil ? 0 : 1)
    .opacity(grabbed == nil ? 1 : 0.85)
    .id(i)  // scrollTo(active) は平坦 index
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
