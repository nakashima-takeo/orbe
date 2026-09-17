import SwiftUI

/// ツリー行 20: 深さぶんのガイド、ディレクトリはシェブロン／ファイルは種別チップ、名前（色はバッジに従う）、
/// 右端に git バッジ。ホバーは淡い塗り、選択は selectionFill。
struct TreeRowView: View {
  let row: FileTree.Row
  let tree: FileTree
  let shell: EditorShellModel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.chromeFontResolver) private var fontResolver

  private static let hoverFillAlpha = 0.045

  var body: some View {
    let ink = EditorInk(scheme)
    let badge = row.badge
    HStack(spacing: 0) {
      TreeGuides(depth: row.depth, ink: ink)
      switch row.kind {
      case .directory(let isExpanded): TreeChevron(open: isExpanded)
      case .file: FileChipView(chip: FileChip.resolve(row.url))
      case .input: EmptyView()
      }
      fontResolver.text(row.name, base: Theme.Typography.editorTreeRow)
        .font(Font.theme.editorTreeRow)
        .foregroundStyle(badge?.color ?? Color.theme.editorText)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, Theme.Space.note)
      Spacer(minLength: 0)
      if let badge {
        Text(badge.label)
          .font(Font.theme.editorBadge)
          .foregroundStyle(badge.color)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorRow)
    .background(
      row.isSelected
        ? Color.theme.selectionFill : hovering ? ink.fill(Self.hoverFillAlpha) : .clear
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture {
      switch row.kind {
      case .directory: tree.toggle(row.id)
      case .file: shell.open(row.url)
      case .input: break
      }
    }
  }
}

/// 新規作成の行内入力。現れたら first responder、Enter で作る、Esc で取り消す。名前はツリーの状態に束ねる——
/// 容器が行を捨てて作り直しても打ちかけは残り、入力の終わりは view の寿命ではなく状態が落ちること。
/// 焦点の喪失は pane に知らせ、別の view へ移ったときだけ取り消しになる。
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
      TreeGuides(depth: row.depth, ink: EditorInk(scheme))
      if isDirectory {
        TreeChevron(open: false)
      } else {
        Color.clear.frame(width: Theme.Layout.editorChip, height: Theme.Layout.editorChip)
      }
      TextField("", text: Binding(get: { tree.newEntry?.name ?? "" }, set: tree.setNewName))
        .textFieldStyle(.plain)
        .font(Font.theme.editorTreeRow)
        .foregroundStyle(Color.theme.editorText)
        .tint(Color.theme.accentPrimary)
        .lineLimit(1)
        .focused($focused)
        .padding(.leading, Theme.Space.note)
        .onSubmit { tree.commitNew() }
        .onKeyPress(.escape) {
          tree.cancelNew(generation)
          return .handled
        }
        .onAppear { focused = true }
        .onChange(of: focused) { _, now in
          if now {
            didFocus = true
          } else if didFocus {
            shell.inlineInputLostFocus(generation)
          }
        }
    }
    .padding(.leading, 10)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorRow)
  }
}

/// 深さぶんのインデント線（幅 8 ＋ 右 1px hairline .08、右余白 8）。
struct TreeGuides: View {
  let depth: Int
  let ink: EditorInk

  private static let hairlineAlpha = 0.08

  var body: some View {
    ForEach(0..<depth, id: \.self) { _ in
      Color.clear
        .frame(width: Theme.Space.step)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
          Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(width: Theme.Stroke.hairline)
        }
        .padding(.trailing, Theme.Space.step)
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

  /// バッジと、その行の名前の色。M は変更の黄、A / U は追加の緑、競合は conflict。
  var color: Color {
    switch self {
    case .modified: return Color.theme.editorModified
    case .added, .untracked: return Color.theme.diffAdded
    case .conflicted: return Color.theme.conflict
    }
  }
}
