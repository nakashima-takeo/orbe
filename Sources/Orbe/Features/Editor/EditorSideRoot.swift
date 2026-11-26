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

/// 左の列: エクスプローラー（ヘッダー・ルート行・ツリー）。ツリーのスクロール位置はツリーが覚え、画面を切り替えて・左の列を
/// 閉じて・検索パネルから戻って作り直されても戻す。隠れている間に選択が替わっていれば、位置を戻す代わりに選択の行を見せる。
struct ExplorerView: View {
  let shell: EditorShellModel
  let tree: FileTree
  /// 作り直した一覧を戻す位置（作られた時点でツリーが覚えていた位置。戻し終えたら nil）。中身が溢れるまで戻さずに待ち、その間の
  /// 位置の知らせで覚えた位置を書き換えない。
  @State private var pendingFraction: CGFloat?
  /// 作り直した一覧で見せる選択の行（隠れている間に選択が替わったとき）。最初のレイアウトの後に 1 度だけ中ほどへ送って
  /// 終える——行を宛先に送るので、中身が溢れるのを待たない（収まっていれば何も動かない）。
  @State private var pendingReveal: String?

  init(shell: EditorShellModel, tree: FileTree) {
    self.shell = shell
    self.tree = tree
    let selected = tree.selected
    let reveals = selected != nil && selected != tree.scrolledSelection
    _pendingReveal = State(initialValue: reveals ? selected : nil)
    _pendingFraction = State(
      initialValue: !reveals && tree.scrollFraction > 0 ? tree.scrollFraction : nil)
  }
  @Environment(\.localization) private var l10n

  /// ツリーの中身全体の id（つまみのドラッグと位置の戻しが比の anchor で送る先。行の id と型で分ける）。
  private enum Content: Hashable { case tree }

  /// 送れる範囲（pt）。
  private static func range(_ geometry: ScrollGeometry) -> CGFloat {
    geometry.contentSize.height - geometry.containerSize.height
  }

  var body: some View {
    EditorSidebarPanel {
      header
      rootRow
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(tree.rows) { row in
              if case .input(let isDirectory, let generation) = row.kind {
                InlineInputRow(
                  row: row, isDirectory: isDirectory, generation: generation, tree: tree,
                  shell: shell)
              } else {
                TreeRowView(row: row, tree: tree, shell: shell)
              }
            }
          }
          // 最後の行の下に行 1 つ分の空き（末尾まで送っても最後の行が下端に付かない）。つまみが測る中身に含める。
          .padding(.bottom, Theme.Layout.editorRow)
          .sidebarScrollContent(id: Content.tree)
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: \.self) { _, geometry in
          let range = Self.range(geometry)
          if let path = pendingReveal {
            // 位置の戻しと同じく、レイアウトを終えてから送る。
            pendingReveal = nil
            Task { @MainActor in proxy.scrollTo(path, anchor: .center) }
          }
          if let pending = pendingFraction {
            guard range > 0 else { return }
            // 作り直した一覧を、覚えた位置へ送る（比の anchor はつまみのドラッグと同じ送り方）。位置の知らせはレイアウトの
            // 最中に届き、その場で送る要求は捨てられることがあるので、レイアウトを終えてから送る。
            pendingFraction = nil
            Task { @MainActor in proxy.scrollTo(Content.tree, anchor: UnitPoint(x: 0, y: pending)) }
            return
          }
          tree.scrollFraction = range > 0 ? min(1, max(0, geometry.contentOffset.y / range)) : 0
          tree.scrolledSelection = tree.selected
        }
        .sidebarScrollbar(proxy, contentID: Content.tree)
        // 行は遅延で生まれる（可視域外の行は無い）ので、入力行と選択行は可視位置へ送る。
        .onChange(of: tree.newEntry?.generation) { _, _ in
          if let entry = tree.newEntry { proxy.scrollTo(FileTree.inputRowID(entry)) }
        }
        .onChange(of: tree.selected) { _, path in
          if let path { proxy.scrollTo(path) }
          tree.scrolledSelection = path
        }
      }
    }
  }

  /// 右端の 3 ツール（新規ファイル／新規フォルダ／すべて折りたたむ）。
  private var header: some View {
    EditorPanelHeader(title: l10n.string(.editorExplorerTitle)) {
      EditorIconButton(
        glyph: EditorGlyphs.newFile, help: l10n.string(.editorNewFile), action: shell.createFile)
      EditorIconButton(
        glyph: EditorGlyphs.newFolder, help: l10n.string(.editorNewFolder),
        action: shell.createDirectory)
      EditorIconButton(
        glyph: EditorGlyphs.collapseAll, help: l10n.string(.editorCollapseAll),
        action: shell.collapseAll)
    }
  }

  /// ルート行 20: シェブロン ＋ 根の basename（大文字）。クリックで根の開閉。
  private var rootRow: some View {
    HStack(spacing: 0) {
      TreeChevron(open: tree.isRootOpen)
      Text(tree.rootName)
        .font(Font.theme.editorRootLabel)
        .tracking(Theme.Typography.trackingRootLabel)
        .foregroundStyle(Color.theme.editorText)
        .lineLimit(1)
        .padding(.leading, Theme.Space.hair)
      Spacer(minLength: 0)
    }
    .padding(.leading, 10)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorRow)
    .contentShape(Rectangle())
    .onTapGesture { tree.isRootOpen.toggle() }
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

/// 折りたたみのシェブロン 16。開いていると 90° 回る。
struct TreeChevron: View {
  let open: Bool

  var body: some View {
    EditorGlyphView(
      glyph: EditorGlyphs.chevron, size: Theme.Layout.editorChevron, color: Color.theme.editorIcon
    )
    .rotationEffect(open ? .degrees(90) : .zero)
    .frame(width: Theme.Layout.editorChevron)
  }
}
