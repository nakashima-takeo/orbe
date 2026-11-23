import SwiftUI

/// 左の列: エクスプローラー（上の行・ツリー）。ツリーは根の直下の行から始まる。ツリーのスクロール位置はツリーが覚え、画面を
/// 切り替えて・左の列を閉じて・検索パネルから戻って作り直されても戻す。隠れている間に選択が替わっていれば、位置を戻す代わりに
/// 選択の行を見せる。
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
      topRow
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
          .padding(.horizontal, Theme.Layout.editorTreeInset)
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

  /// 上の行: 左に絞り込みの欄の場所、右に 3 つのツール（新規ファイル／新規フォルダ／すべて折りたたむ）。
  private var topRow: some View {
    HStack(spacing: Theme.Space.hair) {
      Spacer(minLength: 0)
      EditorIconButton(
        glyph: EditorGlyphs.newFile, help: l10n.string(.editorNewFile), action: shell.createFile)
      EditorIconButton(
        glyph: EditorGlyphs.newFolder, help: l10n.string(.editorNewFolder),
        action: shell.createDirectory)
      EditorIconButton(
        glyph: EditorGlyphs.collapseAll, help: l10n.string(.editorCollapseAll),
        action: shell.collapseAll)
    }
    .frame(height: Theme.Layout.editorTreeField)
    .padding(Theme.Layout.editorTreeTopPad)
  }
}
