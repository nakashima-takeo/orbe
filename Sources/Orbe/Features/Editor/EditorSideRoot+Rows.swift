import SwiftUI

/// ツリー行 24: 深さぶんの字下げの線、ディレクトリはシェブロンと名前（mono・弱い色）／ファイルは種別チップと名前、右端に git
/// の状態の字。選択の行は選択の地、ほかはホバーで淡い地（どちらも上下 1 を空けた角丸 6）。選択の行と祖先の行は字下げの線が
/// accent。ファイル行は押すと仮の文書として開き、2 回目の押下（ダブルクリック）で普通の文書として開く——1 回目をダブル
/// クリックの判定で待たせない。
struct TreeRowView: View {
  let row: FileTree.Row
  let tree: FileTree
  let shell: EditorShellModel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: 0) {
      TreeGuides(depth: row.depth, accent: row.isOnSelectionPath, ink: ink)
      switch row.kind {
      case .directory(let isExpanded):
        TreeChevron(open: isExpanded, size: Theme.Layout.editorTreeChevron)
        Text(row.name)
          .font(Font.theme.editorTreeFolder)
          .foregroundStyle(Color.theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.head)
          .padding(.leading, Theme.Layout.editorTreeNameGap)
      case .file:
        FileChipView(chip: FileChip.resolve(row.url))
          .padding(.trailing, Theme.Layout.editorTreeChipGap)
        fontResolver.text(row.name, base: Theme.Typography.editorTreeRow)
          .font(Font.theme.editorTreeRow)
          .foregroundStyle(row.isSelected ? Color.theme.textPrimary : Color.theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
      case .input: EmptyView()
      }
      Spacer(minLength: 0)
      if let badge = row.badge {
        Text(badge.label)
          .font(Font.theme.editorTreeBadge)
          .foregroundStyle(badge.color)
          .frame(width: Theme.Layout.editorTreeBadge)
      }
    }
    .padding(.horizontal, Theme.Layout.editorTreeRowPadX)
    .frame(height: Theme.Layout.editorRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorTreeRowRadius)
        .fill(
          row.isSelected
            ? Color.theme.selectionFill
            : hovering ? ink.fill(Theme.Opacity.editorTreeHover) : .clear
        )
        .padding(.vertical, Theme.Layout.editorTreeRowGroundInset)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture {
      switch row.kind {
      case .directory: tree.toggle(row.id)
      case .file: shell.open(row.url, .preview)
      case .input: break
      }
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        if case .file = row.kind { shell.open(row.url, .pinned) }
      })
  }
}

/// 新規作成の行内入力。現れたら first responder（窓か面が持っているとき）、Enter で作る、Esc で取り消す。
/// 名前はツリーの状態に束ねる——容器が行を捨てて作り直しても打ちかけは残り、入力の終わりは view の寿命では
/// なく状態が落ちること。焦点の喪失は pane に知らせ、別の view へ移ったときだけ取り消しになる。
struct InlineInputRow: View {
  let row: FileTree.Row
  let isDirectory: Bool
  let generation: Int
  let tree: FileTree
  let shell: EditorShellModel
  @FocusState private var focused: Bool
  @State private var didFocus = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 0) {
      TreeGuides(depth: row.depth, accent: false, ink: EditorInk(scheme))
      if isDirectory {
        TreeChevron(open: false, size: Theme.Layout.editorTreeChevron)
          .padding(.trailing, Theme.Layout.editorTreeNameGap)
      } else {
        Color.clear.frame(width: Theme.Layout.editorChip, height: Theme.Layout.editorChip)
          .padding(.trailing, Theme.Layout.editorTreeChipGap)
      }
      TextField("", text: Binding(get: { tree.newEntry?.name ?? "" }, set: tree.setNewName))
        .textFieldStyle(.plain)
        .font(Font.theme.editorTreeRow)
        .foregroundStyle(Color.theme.editorText)
        .tint(Color.theme.accentPrimary)
        .lineLimit(1)
        .focused($focused)
        .onSubmit { tree.commitNew() }
        .onKeyPress(.escape) {
          tree.cancelNew(generation)
          return .handled
        }
        .onAppear { if shell.inlineInputMayTakeFocus() { focused = true } }
        .onChange(of: focused) { _, now in
          if now {
            didFocus = true
          } else if didFocus {
            shell.inlineInputLostFocus(generation)
          }
        }
    }
    .padding(.horizontal, Theme.Layout.editorTreeRowPadX)
    .frame(height: Theme.Layout.editorRow)
  }
}

/// 深さぶんの字下げの線（1 段 14 の中央に 1px。`accent` なら accent の色、ほかは hairline .15）。
struct TreeGuides: View {
  let depth: Int
  let accent: Bool
  let ink: EditorInk

  var body: some View {
    ForEach(0..<depth, id: \.self) { _ in
      Rectangle()
        .fill(accent ? Color.theme.accentPrimary : ink.hairline(Theme.Opacity.editorTreeGuide))
        .frame(width: Theme.Stroke.hairline)
        .frame(width: Theme.Layout.editorTreeGuide)
        .frame(maxHeight: .infinity)
    }
  }
}

extension FileTree.Row {
  var badge: GitStatus.Badge? {
    if case .file(let badge) = kind { return badge }
    return nil
  }
}

extension GitStatus.Badge {
  var label: String {
    switch self {
    case .modified: return "M"
    case .added: return "A"
    case .untracked: return "U"
    case .conflicted: return "C"
    }
  }

  /// 状態の字の色。M は git の変更、A / U は git の追加、競合は conflict。
  var color: Color {
    switch self {
    case .modified: return Color.theme.diffModified
    case .added, .untracked: return Color.theme.diffAdded
    case .conflicted: return Color.theme.conflict
    }
  }
}
