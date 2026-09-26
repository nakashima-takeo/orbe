import AppKit
import OrbeEditorCore
import SwiftUI

/// 結果の列: まとまりの見出しと一致の平らな行（LazyVStack。エクスプローラーのツリーと同じ組み方）。焦点を取れる列で、
/// ↑↓ は選択だけを動かし（開かない）、← → は折りたたみと親子の移動、Enter は開閉か開いてテキスト面へ、Esc は止めるか
/// 選択を外す。一致のシングルクリックは選んで開き（焦点は列に残る）、ダブルクリックは開いてテキスト面へ。
struct SearchResultsList: View {
  let search: ProjectSearch
  var focus: FocusState<ProjectSearch.Area?>.Binding

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          ForEach(search.rows) { row in
            SearchResultRow(row: row, isSelected: row.id == search.selection, search: search)
          }
        }
      }
      .focusable()
      .focusEffectDisabled()
      .focused(focus, equals: .results)
      .onKeyPress(.upArrow) { handled { search.moveSelection(by: -1) } }
      .onKeyPress(.downArrow) { handled { search.moveSelection(by: 1) } }
      .onKeyPress(.leftArrow) { handled { search.moveLeft() } }
      .onKeyPress(.rightArrow) { handled { search.moveRight() } }
      .onKeyPress(.return) { handled { search.activateSelection() } }
      .onKeyPress(.escape) { handled { search.escapeInResults() } }
      .onChange(of: search.selection) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }

  private func handled(_ action: () -> Void) -> KeyPress.Result {
    action()
    return .handled
  }
}

/// 結果の 1 行（見出しか一致）。選択は selectionFill。
private struct SearchResultRow: View {
  let row: ProjectSearch.Row
  let isSelected: Bool
  let search: ProjectSearch

  var body: some View {
    Group {
      switch row {
      case .file(let file, let isCollapsed): SearchFileRow(file: file, isCollapsed: isCollapsed)
      case .match(_, _, let match): SearchMatchRow(match: match)
      }
    }
    .background(isSelected ? Color.theme.selectionFill : .clear)
    .contentShape(Rectangle())
    .onTapGesture {
      // 素のクリックの回数で分ける（`count: 2` の組み合わせはシングルクリックをダブルクリックの猶予だけ遅らせる）。
      if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
        search.doubleClick(row.id)
      } else {
        search.click(row.id)
      }
    }
  }
}

/// まとまりの見出し 22: シェブロン（畳むと右向き）・種別チップ 14・ファイル名 12・ディレクトリ 10.5 tertiary・右端の件数。
private struct SearchFileRow: View {
  let file: SearchFileMatches
  let isCollapsed: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.chromeFontResolver) private var fontResolver

  private static let countFillAlpha = 0.10

  var body: some View {
    let name = (file.path as NSString).lastPathComponent
    let directory = (file.path as NSString).deletingLastPathComponent
    HStack(spacing: Theme.Space.note) {
      EditorGlyphView(
        glyph: EditorGlyphs.chevron, size: Theme.Layout.editorSearchChevron,
        color: Color.theme.textMuted
      )
      .rotationEffect(isCollapsed ? .zero : .degrees(90))
      .frame(width: Theme.Layout.editorSearchChevron)
      FileChipView(chip: FileChip.resolve(URL(fileURLWithPath: file.path)))
      fontResolver.text(name, base: Theme.Typography.editorSearchFile)
        .font(Font.theme.editorSearchFile)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .layoutPriority(1)
      fontResolver.text(directory, base: Theme.Typography.editorSearchDirectory)
        .font(Font.theme.editorSearchDirectory)
        .foregroundStyle(Color.theme.editorTertiary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
      Text("\(file.count)")
        .font(Font.theme.editorSearchCount)
        .foregroundStyle(Color.theme.textSecondary)
        .padding(.horizontal, 5)
        .frame(
          minWidth: Theme.Layout.editorSearchCountWidth,
          minHeight: Theme.Layout.editorSearchCountHeight
        )
        .background(Capsule().fill(EditorInk(scheme).fill(Self.countFillAlpha)))
    }
    .padding(.horizontal, Theme.Space.beat)
    .frame(height: Theme.Layout.editorSearchFileRow)
  }
}

/// 一致の行 20（左 40・mono 11）: 前 tertiary、ヒット（地 tint(modified, .30) 角 2・文字 primary）、後ろ muted。
private struct SearchMatchRow: View {
  let match: SearchMatch

  private static let hitAlpha = 0.30
  private static let hitRadius: CGFloat = 2

  var body: some View {
    // 列が狭いときは後ろ → 前（頭を省略）→ ヒットの順に詰める。
    HStack(spacing: 0) {
      Text(match.preview.before)
        .foregroundStyle(Color.theme.editorTertiary)
        .lineLimit(1)
        .truncationMode(.head)
        .layoutPriority(1)
      Text(match.preview.match)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .background(
          RoundedRectangle(cornerRadius: Self.hitRadius)
            .fill(Color.theme.editorModified.opacity(Self.hitAlpha))
        )
        .layoutPriority(2)
      Text(match.preview.after)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(Font.theme.editorSearchMatch)
    .padding(.leading, Theme.Layout.editorSearchMatchIndent)
    .padding(.trailing, Theme.Space.beat)
    .frame(height: Theme.Layout.editorSearchMatchRow)
  }
}
