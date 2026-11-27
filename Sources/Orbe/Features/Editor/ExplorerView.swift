import SwiftUI

/// 左の列: エクスプローラー（上の行・文の行・ツリー）。ツリーは根の直下の行から始まる。2 つの入力（絞り込みの欄・行内入力）の
/// フォーカスは、ツリーの 1 つの値（`explorerFocus`）へ写す——絞り込みの欄は欄の first responder の出入りから（押した時点で
/// 届く）、行内入力は `focus` から（その後の SwiftUI の更新で届く）。行内入力から欄へ移ったときは、欄の分が先に値を替えるので、
/// 行内入力の「抜けた」は値を戻さない。ツリーのスクロール位置はツリーが覚え、画面を切り替えて・左の列を閉じて・検索パネルから
/// 戻って作り直されても戻す。隠れている間に選択が替わっていれば、位置を戻す代わりに選択の行を見せる。
struct ExplorerView: View {
  let shell: EditorShellModel
  let tree: FileTree
  /// 作り直した一覧を戻す位置（作られた時点でツリーが覚えていた位置。戻し終えたら nil）。中身が溢れるまで戻さずに待ち、その間の
  /// 位置の知らせで覚えた位置を書き換えない。
  @State private var pendingFraction: CGFloat?
  /// 作り直した一覧で見せる選択の行の同一性（隠れている間に選択が替わったとき）。最初のレイアウトの後に 1 度だけ中ほどへ送って
  /// 終える——行を宛先に送るので、中身が溢れるのを待たない（収まっていれば何も動かない）。
  @State private var pendingReveal: String?
  /// 行内入力のフォーカス（`.input` だけを取る）。
  @FocusState private var focus: FileTree.ExplorerFocus?

  init(shell: EditorShellModel, tree: FileTree) {
    self.shell = shell
    self.tree = tree
    let selected = tree.selected
    let reveals = selected != nil && selected != tree.scrolledSelection
    _pendingReveal = State(initialValue: reveals ? tree.selectedRowID : nil)
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
      ExplorerFilterNotes(filter: tree.filter)
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(tree.rows) { row in
              if case .input(let isDirectory, let generation) = row.kind {
                InlineInputRow(
                  row: row, isDirectory: isDirectory, generation: generation, tree: tree,
                  shell: shell, focus: $focus)
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
          if let id = tree.selectedRowID { proxy.scrollTo(id) }
          tree.scrolledSelection = path
        }
        // 絞り込みの結果が替わったら（字が替わった結果）一覧の先頭へ、絞り込みを解いたら選択を含む行を中ほどへ送る。
        .onChange(of: tree.filter.shown?.text) { _, text in
          guard text != nil else { return }
          Task { @MainActor in proxy.scrollTo(Content.tree, anchor: .top) }
        }
        .onChange(of: tree.filter.isActive) { _, active in
          guard !active, let id = tree.selectedRowID else { return }
          Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
    .onChange(of: focus) { old, new in
      if let new {
        tree.explorerFocus = new
      } else if case .input(let generation) = old, tree.explorerFocus == old {
        tree.explorerFocus = nil
        shell.inlineInputLostFocus(generation)
      }
    }
    .onDisappear { tree.explorerFocus = nil }
  }

  /// 上の行: 左に絞り込みの欄、右に 3 つのツール（新規ファイル／新規フォルダ／すべて折りたたむ）。結果を 0.3 秒より長く
  /// 待っている間は、下端に進捗の細い線。
  private var topRow: some View {
    HStack(spacing: Theme.Space.hair) {
      ExplorerFilterField(tree: tree, shell: shell)
        .padding(.trailing, Theme.Layout.editorTreeFieldGap)
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
    .overlay(alignment: .bottom) {
      if tree.filter.isWaiting { EditorProgressLine() }
    }
  }
}

/// 絞り込みの欄（入力欄の枠の高さ 26）。字はツリーの状態に束ねる（view が作り直されても残る）。esc は、字があれば空にし
/// （フォーカスは欄のまま）、空なら本体の行き先へフォーカスを移す（キーリピートの esc も同じ）。変換中の esc は変換の取り消し。
/// ↵ は何もしない。フォーカスは押して入り、出入りをツリーの `explorerFocus` へ写す。
private struct ExplorerFilterField: View {
  let tree: FileTree
  let shell: EditorShellModel
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorFieldFrame(
      height: Theme.Layout.editorTreeField, isFocused: tree.explorerFocus == .filter
    ) {
      EditorTextField(
        text: tree.filter.text, placeholder: l10n.string(.editorFilterPlaceholder),
        font: Theme.Typography.editorTreeFilter, placeholderColor: Theme.Color.textMuted,
        onTextChange: tree.setFilterText,
        onFocusChange: { focused in
          if focused {
            tree.explorerFocus = .filter
          } else if tree.explorerFocus == .filter {
            tree.explorerFocus = nil
          }
        },
        onEscape: { _ in
          if tree.filter.isActive {
            tree.setFilterText("")
          } else {
            shell.focusBody()
          }
        })
    }
  }
}

/// 文の行（上の行のすぐ下。sans 11・弱い色）: 0 件・一致の打ち切り・一覧の打ち切り・一覧を取れずにいる。
private struct ExplorerFilterNotes: View {
  let filter: FileTreeFilter
  @Environment(\.localization) private var l10n

  var body: some View {
    let lines = self.lines
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        ForEach(lines, id: \.self) { line in
          Text(l10n.string(line)).fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(Font.theme.editorSearchNote)
      .foregroundStyle(Color.theme.editorTertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Space.beat)
      .padding(.bottom, Theme.Space.step)
    }
  }

  private var lines: [L10nKey] {
    guard filter.isActive else { return [] }
    if filter.listFailed { return [.editorFilterListFailed] }
    guard let result = filter.shown else { return [] }
    var lines: [L10nKey] = []
    if result.matchCount == 0 { lines.append(.editorFilterNoMatches) }
    if result.matchesTruncated { lines.append(.editorFilterTooManyMatches) }
    if result.listTruncated { lines.append(.editorFilterTooManyFiles) }
    return lines
  }
}
