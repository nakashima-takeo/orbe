import SwiftUI

/// ツリー行 24: 深さぶんの字下げの線、ディレクトリはシェブロンと名前（mono。連なりは前の段を弱い色、最後の段をそれより
/// 強い色で出し、幅が足りなければ頭から省く）／ファイルは種別チップと名前、右端に git
/// の状態の字。選択の行は選択の地、ほかはホバーで淡い地（どちらも上下 1 を空けた角丸 6）。選択の行と祖先の行は字下げの線が
/// accent。ファイル行は押すと仮の文書として開き、2 回目の押下（ダブルクリック）で普通の文書として開く——1 回目をダブル
/// クリックの判定で待たせない。開いている行の印の枠は、行の押下の外に重ねる——× の押下を、行のダブルクリックの 1 回目に
/// 数えさせない。
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
        (fontResolver.text(row.prefix, base: Theme.Typography.editorTreeFolder)
          .foregroundStyle(Color.theme.textMuted)
          + fontResolver.text(row.name, base: Theme.Typography.editorTreeFolder)
          .foregroundStyle(Color.theme.textSecondary))
          .font(Font.theme.editorTreeFolder)
          .lineLimit(1)
          .truncationMode(.head)
          .padding(.leading, Theme.Layout.editorTreeNameGap)
      case .file:
        FileChipView(chip: FileChip.resolve(row.url))
          .padding(.trailing, Theme.Layout.editorTreeChipGap)
        fontResolver.text(row.name, base: Theme.Typography.editorTreeRow)
          .font(Font.theme.editorTreeRow)
          .foregroundStyle(
            row.isSelected || row.mark != nil ? Color.theme.textPrimary : Color.theme.textSecondary
          )
          .lineLimit(1)
          .truncationMode(.tail)
      case .input: EmptyView()
      }
      Spacer(minLength: 0)
      if row.mark != nil {
        // 印の枠の場所（枠は行の押下の外に重ねる → 下の overlay）。
        Color.clear
          .frame(width: Theme.Layout.editorItemListMark)
          .padding(.trailing, Theme.Layout.editorTreeChipGap)
      }
      if let badge = row.badge {
        Text(badge.label)
          .font(Font.theme.editorTreeBadge)
          .foregroundStyle(badge.color)
          .frame(width: Theme.Layout.editorTreeBadge)
      }
    }
    .padding(.horizontal, Theme.Layout.editorTreeRowPadX)
    .frame(height: Theme.Layout.editorRow)
    .background(ground(ink))
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
      }
    )
    .overlay(alignment: .trailing) {
      if let mark = row.mark {
        TreeMarkButton(mark: mark) { frame in shell.closeDocument(row.url, frame) }
          .padding(.trailing, markTrailing)
      }
    }
  }

  /// 印の枠の右の空き（行の右の余白・枠の右の空き・git の字の列）。
  private var markTrailing: CGFloat {
    Theme.Layout.editorTreeRowPadX + Theme.Layout.editorTreeChipGap
      + (row.badge == nil ? 0 : Theme.Layout.editorTreeBadge)
  }

  /// 地: 選択の行は選択の地、開いている行は淡い地と枠、ほかはホバーで淡い地（どれも上下 1 を空けた角丸 6）。
  private func ground(_ ink: EditorInk) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Layout.editorTreeRowRadius)
    let isOpen = row.mark != nil && !row.isSelected
    let fill: Color =
      row.isSelected
      ? Color.theme.selectionFill
      : isOpen
        ? Color.theme.surfaceInk.opacity(Theme.Opacity.editorTreeOpen)
        : hovering ? ink.fill(Theme.Opacity.editorTreeHover) : .clear
    return shape.fill(fill)
      .overlay {
        if isOpen {
          shape.strokeBorder(
            Color.theme.surfaceInk.opacity(Theme.Opacity.editorTreeOpenBorder),
            lineWidth: Theme.Stroke.hairline)
        }
      }
      .padding(.vertical, Theme.Layout.editorTreeRowGroundInset)
  }
}

/// 開いている行の印の枠 16。× か丸で、丸は枠にポインタがある間だけ × に替わる。× はホバーで枠に地が付く。押すと、枠（左の
/// 列の host の座標）を添えて文書を閉じる（行の押下にはならない。続く押下の扱いは受け手が決める）。
struct TreeMarkButton: View {
  let mark: EditorItemListRow.Mark
  let action: (CGRect) -> Void
  @State private var hovering = false
  @State private var frame = CGRect.zero
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    let size = Theme.Layout.editorItemListMark
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm)
    ZStack {
      if mark == .close || hovering {
        shape.fill(
          hovering ? EditorInk(scheme).fill(Theme.Opacity.editorItemListMarkHover) : .clear)
        EditorGlyphView(
          glyph: EditorGlyphs.close, size: Theme.Layout.editorItemListMarkGlyph,
          color: hovering ? Color.theme.textPrimary : Color.theme.textMuted)
      } else {
        EditorMarkDot(mark, size: Theme.Layout.editorItemDot)
      }
    }
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(EditorSideRoot.space))
    } action: {
      frame = $0
    }
    .onTapGesture { action(frame) }
    .help(l10n.string(.editorItemListClose))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(l10n.string(.editorItemListClose))
    .accessibilityAddTraits(.isButton)
  }
}

/// 新規作成の行内入力。現れたら焦点を取り（窓か面が持っているとき）、Enter で作る、Esc で取り消す。
/// 名前はツリーの状態に束ねる——容器が行を捨てて作り直しても打ちかけは残り、入力の終わりは view の寿命では
/// なく状態が落ちること。焦点はエクスプローラーが絞り込みの欄と 1 つの値で持ち、その出入りはエクスプローラーが扱う。
struct InlineInputRow: View {
  let row: FileTree.Row
  let isDirectory: Bool
  let generation: Int
  let tree: FileTree
  let shell: EditorShellModel
  var focus: FocusState<FileTree.ExplorerFocus?>.Binding
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
        .focused(focus, equals: .input(generation: generation))
        .onSubmit { tree.commitNew() }
        .onKeyPress(.escape) {
          tree.cancelNew(generation)
          return .handled
        }
        .onAppear {
          if shell.inlineInputMayTakeFocus() {
            focus.wrappedValue = .input(generation: generation)
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
    if case .file(let badge, _) = kind { return badge }
    return nil
  }

  /// 開いている文書の印（開いていなければ nil）。
  var mark: EditorItemListRow.Mark? {
    if case .file(_, let mark) = kind { return mark }
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
