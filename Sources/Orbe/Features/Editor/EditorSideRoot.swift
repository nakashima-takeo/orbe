import SwiftUI

/// 左の列（エクスプローラー・検索パネル・ソース管理パネル・PR のパネル）の SwiftUI ルート。器の中の別 root なので環境は明示
/// 注入する。中身は画面で決まる（`EditorShellModel.Panel`）。幅は pane が決める（左の列の表示幅 ＋ hairline）——左の列の幅の
/// 持ち主は pane で、ここは与えられた幅を埋めるだけ。左の列を閉じている間は中身を置かない（パネルは隠れたことになる）。
struct EditorSideRoot: View {
  let shell: EditorShellModel
  let tree: FileTree
  let search: ProjectSearch
  /// 検索結果の列（pane が持ち、パネルが隠れても捨てない）。
  let searchResults: RowList<SearchResultsSource>
  let scm: ScmPanel
  /// ソース管理の変更の列とグラフの列（検索結果の列と同じく pane が持つ）。
  let scmList: RowList<ScmListSource>
  let scmGraphList: RowList<ScmGraphSource>
  /// PR のパネルの状態と列と列の頭（ソース管理と同じく pane が持つ）。
  let pullRequest: PrPanel
  let pullRequestList: RowList<PrListSource>
  let pullRequestHeader: PrDescriptionHeader
  /// 開閉とグラフの枠の高さの持ち主（pane と同じ 1 つ。写しを挟まない）。
  let sidebar: EditorSidebarState
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  /// host 全体の座標空間（左上が原点。host の座標と一致する）。中の部品が、自分の枠を面へ渡すときに使う。
  static let space = "editorSide"

  var body: some View {
    // GeometryReader は中身の最小幅に縛られず host の幅を取る——エクスプローラーのヘッダー（3 ボタン）より狭く切り詰め
    // られても root が中央寄せで左へずれない。溢れは右で、切り落とす。
    GeometryReader { _ in
      Diag509Mark("side body panel=\(shell.panel) open=\(sidebar.isOpen)")
      if sidebar.isOpen {
        switch shell.panel {
        case .files:
          ExplorerView(shell: shell, tree: tree)
            .onAppear { Diag509.log("explorer appear") }
            .onDisappear { Diag509.log("explorer disappear") }
        case .search:
          SearchPanelView(search: search, results: searchResults)
            .onAppear { Diag509.log("search panel appear (outer)") }
            .onDisappear { Diag509.log("search panel disappear (outer)") }
        case .sourceControl:
          ScmPanelView(panel: scm, list: scmList, graphList: scmGraphList, sidebar: sidebar)
        case .pullRequest:
          PrPanelView(panel: pullRequest, list: pullRequestList, header: pullRequestHeader)
        }
      }
    }
    .clipped()
    .coordinateSpace(.named(Self.space))
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// 左の列のパネルの器: 上から積む中身と右の hairline。地は沈み面、ぼかしは持たない。
struct EditorSidebarPanel<Content: View>: View {
  @ViewBuilder let content: Content
  @Environment(\.colorScheme) private var scheme

  private var sunkAlpha: Double { 0.45 }
  private var hairlineAlpha: Double { 0.07 }

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: 0) {
      VStack(spacing: 0) { content }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      Rectangle().fill(ink.hairline(hairlineAlpha)).frame(width: Theme.Stroke.hairline)
    }
    .frame(maxHeight: .infinity)
    .background(ink.sunk(sunkAlpha))
  }
}

/// パネルヘッダー 28: 題と、右端のツール。
struct EditorPanelHeader<Tools: View>: View {
  let title: String
  @ViewBuilder let tools: Tools

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(Font.theme.editorPanelTitle)
        .tracking(Theme.Typography.trackingPanelTitle)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
      Spacer(minLength: 0)
      HStack(spacing: Theme.Space.hair) { tools }
    }
    .padding(.leading, 18)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorPanelHeader)
  }
}

/// 22 角のアイコンボタン（radius 4。ホバーで地 fill .08 ＋ 文字が上がる）。
struct EditorIconButton: View {
  let glyph: EditorGlyphs.Glyph
  let help: String
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme

  private static let hoverFillAlpha = 0.08
  private let size: CGFloat = 22
  private let glyphSize: CGFloat = 15

  var body: some View {
    EditorGlyphView(
      glyph: glyph, size: glyphSize,
      color: hovering ? Color.theme.editorText : Color.theme.textMuted
    )
    .frame(width: size, height: size)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.sm)
        .fill(hovering ? EditorInk(scheme).fill(Self.hoverFillAlpha) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: action)
    .help(help)
  }
}

/// 折りたたみのシェブロン（既定 16）。開いていると 90° 回る。
struct TreeChevron: View {
  let open: Bool
  var size = Theme.Layout.editorChevron

  var body: some View {
    EditorGlyphView(glyph: EditorGlyphs.chevron, size: size, color: Color.theme.editorIcon)
      .rotationEffect(open ? .degrees(90) : .zero)
      .frame(width: size)
  }
}
