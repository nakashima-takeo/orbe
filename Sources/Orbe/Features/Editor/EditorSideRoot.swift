import SwiftUI

/// レール＋サイドバー（エクスプローラーか検索パネル）の SwiftUI ルート。器の中の別 root なので環境は明示注入する。
/// 幅は pane が決める（レール 36 ＋ hairline、サイドバーが出るときは ＋幅 ＋ hairline）。レールは固定幅で、
/// パネルは残りを埋める——サイドバーの幅の持ち主は pane で、ここは与えられた幅を埋めるだけ。
struct EditorSideRoot: View {
  let shell: EditorShellModel
  let tree: FileTree
  let search: ProjectSearch
  /// 検索結果の列（pane が持ち、パネルが隠れても捨てない）。
  let searchResults: RowList<SearchResultsSource>
  let outline: EditorOutline
  /// アウトラインの行の列（pane が持ち、閉じても捨てない）。
  let outlineList: OutlineListView
  /// 開閉の真実（pane と同じ 1 つ。写しを挟まない）。
  let sidebar: EditorSidebarState
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    // GeometryReader は中身の最小幅に縛られず host の幅を取る——エクスプローラーのヘッダー（3 ボタン）より
    // 狭く切り詰められても root が中央寄せで左へずれず、レールは 0〜36 に居る。溢れは右で、切り落とす。
    GeometryReader { _ in
      HStack(spacing: 0) {
        RailView(selection: sidebar.isOpen ? sidebar.panel : nil, onSelect: shell.selectPanel)
        if sidebar.isOpen {
          switch sidebar.panel {
          case .files:
            ExplorerView(
              shell: shell, tree: tree, outline: outline, outlineList: outlineList,
              sidebar: sidebar)
          case .search: SearchPanelView(search: search, results: searchResults)
          }
        }
      }
      .frame(maxHeight: .infinity)
    }
    .clipped()
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// レール: 幅 36 のアイコン列。項目は「ファイル」「検索」（サイドバーのパネルと 1 対 1）。選択は左 2px の accent の
/// 縦線 ＋ 淡い地（design-system §5 のエディター面の例外）で、サイドバーが閉じている間は無い（`selection == nil`）。
/// 押すと `onSelect`——選択中の項目ならサイドバーを閉じ、別の項目ならそのパネルへ切り替える（閉じていれば開く）。
struct RailView: View {
  typealias Item = EditorSidebarState.Panel

  let selection: Item?
  let onSelect: (Item) -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  // 見本 Rail.tsx の値。
  private static let sunkAlpha = 0.22
  private static let hairlineAlpha = 0.07
  private static let selectedFillAlpha = 0.04
  private let accentBar: CGFloat = 2

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        ForEach(Item.allCases, id: \.self) { item in
          railItem(item, selected: selection == item, ink: ink)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(item) }
        }
        Spacer(minLength: 0)
      }
      .frame(width: Theme.Layout.editorRail)
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(width: Theme.Stroke.hairline)
    }
    .frame(maxHeight: .infinity)
    .background(ink.sunk(Self.sunkAlpha))
  }

  private func railItem(_ item: Item, selected: Bool, ink: EditorInk) -> some View {
    EditorGlyphView(
      glyph: item == .files ? EditorGlyphs.railFiles : EditorGlyphs.railSearch,
      size: Theme.Layout.editorRailGlyph,
      color: selected ? Color.theme.textPrimary : Color.theme.editorTertiary
    )
    .frame(width: Theme.Layout.editorRail, height: Theme.Layout.editorRail)
    .background(selected ? ink.fill(Self.selectedFillAlpha) : .clear)
    .overlay(alignment: .leading) {
      if selected { Rectangle().fill(Color.theme.accentPrimary).frame(width: accentBar) }
    }
    .help(l10n.string(item == .files ? .editorExplorerTitle : .editorRailSearch))
  }
}

/// サイドバーのパネルの器: 上から積む中身と右の hairline。地は沈み面、ぼかしは持たない（見本 parts.tsx の Sidebar）。
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

/// パネルヘッダー 28: 題と、右端のツール（見本 editor/parts.tsx の PanelHeader）。
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

/// サイドバー: エクスプローラー。上の区画（ヘッダー・ルート行・ツリー）と下の区画（アウトライン）の縦 2 段。アウトラインが
/// 閉じている間は見出しだけが下端に残り、ツリーが残りを全部取る。開いている間はパネルの高さに対する比で分け、境を
/// ドラッグできる（両方の区画に最小の高さを残す）。
struct ExplorerView: View {
  let shell: EditorShellModel
  let tree: FileTree
  let outline: EditorOutline
  let outlineList: OutlineListView
  let sidebar: EditorSidebarState
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      GeometryReader { geometry in
        let height = geometry.size.height
        let outlineHeight = self.outlineHeight(in: height)
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            header
            rootRow
            treeRows
          }
          .frame(height: max(0, height - outlineHeight), alignment: .top)
          OutlineSectionView(outline: outline, list: outlineList, sidebar: sidebar)
            .frame(height: outlineHeight, alignment: .top)
            .overlay(alignment: .top) {
              if sidebar.isOutlineOpen {
                SectionResizeHandle(
                  grab: { self.outlineHeight(in: height) },
                  drag: { sidebar.setOutlineFraction($0 / max(1, height)) },
                  release: sidebar.commit
                )
                .frame(height: Theme.Layout.editorSidebarHandle)
                .offset(y: -Theme.Layout.editorSidebarHandle / 2)
              }
            }
        }
      }
    }
  }

  /// アウトラインの区画の高さ（上の hairline 込み）。閉じていれば見出しだけ。開いていれば比で分け、下の区画に見出しと行 3 本、
  /// 上の区画にヘッダー・ルート行と行 3 本を残す（足りなければ下を優先して見出しは必ず残す）。
  private func outlineHeight(in height: CGFloat) -> CGFloat {
    let head = Theme.Stroke.hairline + Theme.Layout.editorSectionHeader
    guard sidebar.isOutlineOpen else { return head }
    let minimum = head + Theme.Layout.editorSectionMinBody
    let maximum =
      height - Theme.Layout.editorPanelHeader - Theme.Layout.editorRow
      - Theme.Layout.editorSectionMinBody
    return max(head, min(max(minimum, (height * sidebar.outlineFraction).rounded()), maximum))
  }

  private var treeRows: some View {
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
      }
      // 行は遅延で生まれる（可視域外の行は無い）ので、入力行と選択行は可視位置へ送る。
      .onChange(of: tree.newEntry?.generation) { _, _ in
        if let entry = tree.newEntry { proxy.scrollTo(FileTree.inputRowID(entry)) }
      }
      .onChange(of: tree.selected) { _, path in
        if let path { proxy.scrollTo(path) }
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
