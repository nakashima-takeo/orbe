import SwiftUI

/// レール＋サイドバー（エクスプローラー）の SwiftUI ルート。器の中の別 root なので環境は明示注入する。
/// 幅は pane が決める（レール 52、サイドバーが出るときは ＋272）。
struct EditorSideRoot: View {
  let shell: EditorShellModel
  let tree: FileTree
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    HStack(spacing: 0) {
      RailView(
        selection: shell.sidebarOpen ? .files : nil, onSelect: { _ in shell.toggleSidebar() })
      if shell.sidebarVisible {
        ExplorerView(shell: shell, tree: tree)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// レール: 幅 36 のアイコン列。項目は「ファイル」1 つ。選択は左 2px の accent の縦線 ＋ 淡い地
/// （design-system §5 のエディター面の例外）で、サイドバーが閉じている間は無い（`selection == nil`）。
/// 押すと `onSelect`——選択中の項目ならサイドバーを閉じ、閉じていれば開く（項目が増えれば別の項目への切替）。
struct RailView: View {
  enum Item: CaseIterable {
    case files
  }

  let selection: Item?
  let onSelect: (Item) -> Void
  @Environment(\.colorScheme) private var scheme

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
      glyph: EditorGlyphs.railFiles, size: Theme.Layout.editorRailGlyph,
      color: selected ? Color.theme.textPrimary : Color.theme.editorTertiary
    )
    .frame(width: Theme.Layout.editorRail, height: Theme.Layout.editorRail)
    .background(selected ? ink.fill(Self.selectedFillAlpha) : .clear)
    .overlay(alignment: .leading) {
      if selected { Rectangle().fill(Color.theme.accentPrimary).frame(width: accentBar) }
    }
  }
}

/// サイドバー: エクスプローラー（ヘッダー・ルート行・ツリー）。地は沈み面、ぼかしは持たない。
struct ExplorerView: View {
  let shell: EditorShellModel
  let tree: FileTree
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  // 見本 parts.tsx（Sidebar）・ExplorerPanel.tsx の値。
  private static let sunkAlpha = 0.45
  private static let hairlineAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        header
        rootRow
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(tree.rows) { row in
              if case .input(let isDirectory) = row.kind {
                InlineInputRow(row: row, isDirectory: isDirectory, tree: tree, shell: shell)
              } else {
                TreeRowView(row: row, tree: tree, shell: shell)
              }
            }
          }
        }
      }
      .frame(width: Theme.Layout.editorSidebar, alignment: .top)
      .frame(maxHeight: .infinity, alignment: .top)
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(width: Theme.Stroke.hairline)
    }
    .frame(maxHeight: .infinity)
    .background(ink.sunk(Self.sunkAlpha))
  }

  /// パネルヘッダー 32: 題と、右端の 3 ツール（新規ファイル／新規フォルダ／すべて折りたたむ）。
  private var header: some View {
    HStack(spacing: 0) {
      Text(l10n.string(.editorExplorerTitle))
        .font(Font.theme.editorPanelTitle)
        .tracking(Theme.Typography.trackingPanelTitle)
        .foregroundStyle(Color.theme.textMuted)
      Spacer(minLength: 0)
      HStack(spacing: Theme.Space.hair) {
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
    .padding(.leading, 18)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorPanelHeader)
  }

  /// ルート行 22: シェブロン ＋ 根の basename（大文字）。クリックで根の開閉。
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
