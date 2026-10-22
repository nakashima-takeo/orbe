import AppKit
import SwiftUI

/// 帯の下を、親「ソース管理」とグラフの枠に割り振る。両方開いていれば、グラフの枠は持っている高さ（親に最低限を残す上限で
/// 丸める）、親は残り。親を畳めばグラフの枠が残りを全部取り、グラフを畳めば見出しだけが下端に寄る（→ `ScmPanelSplit`）。
/// 境目は両方開いているときだけ出し、引けばグラフの枠の高さを変える。
struct ScmSplit: View {
  let panel: ScmPanel
  let list: RowList<ScmListSource>
  let graphList: RowList<ScmGraphSource>
  let sidebar: EditorSidebarState
  /// 親の中で列より上に出ているもの（見出し・欄・ボタン・失敗の文）の高さ。
  @State private var above = Theme.Layout.editorScmRow
  /// 境目を掴んだときのグラフの枠の高さ。
  @State private var grabbed: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      let split = ScmPanelSplit(
        total: proxy.size.height, above: above, stored: sidebar.graphHeight,
        isRepositoryOpen: panel.isRepositoryOpen, isGraphOpen: panel.isGraphOpen)
      VStack(spacing: 0) {
        VStack(spacing: 0) {
          ScmControlsHead(panel: panel)
          if panel.isRepositoryOpen { ScmControls(panel: panel) }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { above = $0 }
        if panel.isRepositoryOpen {
          ScmList(panel: panel, list: list)
        } else {
          Spacer(minLength: 0)
        }
        if !panel.graphLayout.items.isEmpty {
          ScmGraphFrame(panel: panel, list: graphList)
            .frame(height: split.graphHeight)
            .overlay(alignment: .top) {
              if panel.isRepositoryOpen, panel.isGraphOpen { handle(split) }
            }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }
  }

  /// 境目の当たり 4（親とグラフの枠の境に重ねる）。上へ引くとグラフの枠が伸びる。
  private func handle(_ split: ScmPanelSplit) -> some View {
    ScmSplitHandle(
      onDrag: { rise in
        let start = grabbed ?? split.graphHeight
        grabbed = start
        guard let height = split.dragged(to: start + rise) else { return }
        sidebar.setGraphHeight(height)
      },
      onRelease: {
        grabbed = nil
        sidebar.commit()
      }
    )
    .frame(height: Theme.Layout.editorSidebarHandle)
    .offset(y: -Theme.Layout.editorSidebarHandle / 2)
  }
}

/// 親「ソース管理」とグラフの枠の高さの割り振り（純関数）。
struct ScmPanelSplit {
  /// 帯の下の高さ。
  let total: CGFloat
  /// 親の中で列より上に出ているものの高さ。
  let above: CGFloat
  /// 持っているグラフの枠の高さ（下限は持ち主が守る）。
  let stored: CGFloat
  let isRepositoryOpen: Bool
  let isGraphOpen: Bool

  private static let header = Theme.Layout.editorScmRow

  /// 両方開いているときのグラフの枠の上限——親に、列より上に出ているもの＋3 行を残す。
  var ceiling: CGFloat { total - above - Self.header * 3 }

  /// グラフの枠の高さ（見出しを含む）。両方開いていれば持っている高さを上限で丸め、親の下限と両立しなければ下限を割って
  /// 縮む（見出しは残す。コミットの作業の側を優先する）。親を畳めば残りを全部、グラフを畳めば見出しだけ。持っている高さは
  /// 変えない（欄が伸びて縮むたびに、引いた高さを失わない）。
  var graphHeight: CGFloat {
    guard isGraphOpen else { return Self.header }
    guard isRepositoryOpen else { return max(Self.header, total - above) }
    return max(Self.header, min(stored, ceiling))
  }

  /// 境目を引いて求めた高さ `height` から、持たせる高さ（上限で止める）。上限が下限に届かず動かせないとき・見えている高さが
  /// 変わらないときは nil（持っている高さに触れない——高さは「境を動かした」ときだけ変わる）。
  func dragged(to height: CGFloat) -> CGFloat? {
    guard ceiling >= Theme.Layout.editorScmGraphMin else { return nil }
    let target = max(Theme.Layout.editorScmGraphMin, min(height, ceiling))
    return target == graphHeight ? nil : target
  }
}

/// 変更の列（pane が持つ `RowList`）を載せる。読む値（行の版・選択・焦点の要求・絵文字の字体）をここで読んで列へ渡し、言語が
/// 変われば行の文言を読み直させる。
private struct ScmList: View {
  let panel: ScmPanel
  let list: RowList<ScmListSource>
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  var body: some View {
    RowListHost(
      list: list, rowsVersion: panel.rowsVersion, selection: panel.selection,
      emoji: fontResolver.emojiFont, wantsFocus: panel.focusRequest == .list
    )
    .onChange(of: l10n.language, initial: true) { _, language in
      guard list.list.source.language != language else { return }
      list.list.source.language = language
      list.list.reloadRows()
    }
  }
}

/// グラフの枠: 幅いっぱいの 1px の区切り線を上端に重ねた見出し「グラフ」22（padding 0 8 0 4・シェブロン・右端に再読込。親の
/// 見出しと同じ形で、乗ると見出しの帯にだけ地 .04。押せば枠を開閉し、キーでは選べない）と、開いていればグラフの列。
private struct ScmGraphFrame: View {
  let panel: ScmPanel
  let list: RowList<ScmGraphSource>
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let hoverAlpha = 0.04
  private static let dividerAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        TreeChevron(open: panel.isGraphOpen)
        Text(l10n.string(.editorScmGraph))
          .font(Font.theme.editorScmSection)
          .foregroundStyle(Color.theme.editorText)
          .lineLimit(1)
        Spacer(minLength: 0)
        ScmToolButton(
          glyph: EditorGlyphs.refresh, help: l10n.string(.editorScmRefresh), isEnabled: true,
          action: { panel.readGraphAndHead(remoteRefsMayHaveMoved: true) })
      }
      .padding(.leading, Theme.Space.tick)
      .padding(.trailing, Theme.Space.step)
      .frame(height: Theme.Layout.editorScmRow)
      .background(hovering ? ink.fill(Self.hoverAlpha) : .clear)
      .overlay(alignment: .top) {
        Rectangle().fill(ink.hairline(Self.dividerAlpha)).frame(height: Theme.Stroke.hairline)
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture { panel.isGraphOpen.toggle() }
      if panel.isGraphOpen { ScmGraphList(panel: panel, list: list) }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

/// グラフの列（pane が持つ `RowList`）を載せる。焦点を持たない列なので、選択も焦点の要求も渡さない。
private struct ScmGraphList: View {
  let panel: ScmPanel
  let list: RowList<ScmGraphSource>
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  var body: some View {
    RowListHost(
      list: list, rowsVersion: panel.graphRowsVersion, selection: nil,
      emoji: fontResolver.emojiFont, wantsFocus: false
    )
    .onChange(of: l10n.language, initial: true) { _, language in
      guard list.list.source.language != language else { return }
      list.list.source.language = language
      list.list.reloadRows()
    }
  }
}

/// 境目の当たり（AppKit。サイドバーの境の当たり `SidebarResizeHandle` と同じ型）: 乗ると上下の矢印のポインタ、掴んで引くと
/// 連続に追従し、離すと書き戻す。
private struct ScmSplitHandle: NSViewRepresentable {
  /// 掴んだ位置から上へ動いた量（下へなら負）。
  let onDrag: (CGFloat) -> Void
  let onRelease: () -> Void

  func makeNSView(context: Context) -> ScmSplitHandleView { ScmSplitHandleView() }

  func updateNSView(_ view: ScmSplitHandleView, context: Context) {
    view.onDrag = onDrag
    view.onRelease = onRelease
  }
}

final class ScmSplitHandleView: NSView {
  var onDrag: ((CGFloat) -> Void)?
  var onRelease: (() -> Void)?
  /// 掴んだ位置（窓の座標）。
  private var grab: CGFloat?

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.resizeUpDown.set()
  }

  override func mouseDown(with event: NSEvent) {
    grab = event.locationInWindow.y
  }

  override func mouseDragged(with event: NSEvent) {
    guard let grab else { return }
    onDrag?(event.locationInWindow.y - grab)
  }

  override func mouseUp(with event: NSEvent) {
    guard grab != nil else { return }
    grab = nil
    onRelease?()
  }
}
