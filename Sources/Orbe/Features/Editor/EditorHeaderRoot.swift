import SwiftUI

/// 列の頭（ファイルタブ行 28 → 文書があればパンくず 20）の SwiftUI ルート。器の中の別 root なので環境は
/// 明示注入する。文書が無いときはタブ行の帯だけ。
struct EditorHeaderRoot: View {
  let shell: EditorShellModel
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    VStack(spacing: 0) {
      FileTabsView(shell: shell)
        .frame(height: Theme.Layout.editorFileTabs + Theme.Stroke.hairline)
      if shell.activeName != nil {
        BreadcrumbView(shell: shell).frame(height: Theme.Layout.editorBreadcrumb)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// ファイルタブ行: 自然幅のタブを横に並べ、溢れは横スクロール（スクローラー非表示・アクティブを可視位置へ）。
struct FileTabsView: View {
  let shell: EditorShellModel
  @Environment(\.colorScheme) private var scheme

  // 見本 EditorLayer.tsx のタブ行の地と下縁。
  private static let sunkAlpha = 0.22
  private static let hairlineAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(shell.tabs) { tab in
              FileTabView(tab: tab, shell: shell).id(tab.id)
            }
          }
        }
        .onChange(of: shell.activeID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: Theme.Layout.editorFileTabs)
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
    }
    .background(ink.sunk(Self.sunkAlpha))
  }
}

/// タブ 1 枚: チップ ＋ 名前 ＋ 右端の枠（未保存の ● か ×）。アクティブは淡い地と上縁 1.5px の accent
/// （design-system §5 のエディター面の例外）。
struct FileTabView: View {
  let tab: EditorShellModel.FileTab
  let shell: EditorShellModel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.chromeFontResolver) private var fontResolver

  // 見本 CodeView.tsx（FileTabs）の値。
  private static let activeFillAlpha = 0.045
  private static let hairlineAlpha = 0.07
  private let accentBar: CGFloat = 1.5
  private let padLeading: CGFloat = 10

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: Theme.Space.note) {
      FileChipView(chip: tab.chip)
      fontResolver.text(tab.name, base: Theme.Typography.editorFileTab)
        .font(Font.theme.editorFileTab)
        .foregroundStyle(tab.isActive ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
      FileTabCloseSlot(tab: tab, tabHovered: hovering, shell: shell)
    }
    .padding(.leading, padLeading)
    .padding(.trailing, Theme.Layout.editorFileTabTrailing)
    .frame(height: Theme.Layout.editorFileTabs)
    .background(tab.isActive ? ink.fill(Self.activeFillAlpha) : .clear)
    .overlay(alignment: .top) {
      if tab.isActive { Rectangle().fill(Color.theme.accentPrimary).frame(height: accentBar) }
    }
    .overlay(alignment: .trailing) {
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(width: Theme.Stroke.hairline)
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { shell.activate(tab.id) }
  }
}

/// タブの右端の枠に出すもの。アクティブは × を常に、それ以外はタブにポインタがあるときだけ出し（VS Code のタブと
/// 同じ）、未保存はタブにも × にもポインタが無い間だけ × の代わりに ● を出す。
private enum FileTabMark {
  case none
  case dirty
  case close

  init(tab: EditorShellModel.FileTab, pointerInside: Bool) {
    if tab.isDirty && !pointerInside {
      self = .dirty
    } else if tab.isActive || pointerInside {
      self = .close
    } else {
      self = .none
    }
  }
}

/// × の枠（押せる範囲）。× にポインタがあれば枠に地が付き、× の色が上がる。押すと閉じる。
private struct FileTabCloseSlot: View {
  let tab: EditorShellModel.FileTab
  let tabHovered: Bool
  let shell: EditorShellModel
  @State private var hovering = false

  // 見本（デザインキャンバス『ファイルタブの閉じるボタン』A）の値。
  private let dotSize: CGFloat = 8

  var body: some View {
    ZStack {
      switch FileTabMark(tab: tab, pointerInside: tabHovered || hovering) {
      case .none: EmptyView()
      case .dirty:
        Circle()
          .fill(tab.isConflicted ? Color.theme.editorModified : Color.theme.textPrimary)
          .frame(width: dotSize, height: dotSize)
      case .close:
        EditorGlyphView(
          glyph: EditorGlyphs.close, size: Theme.Layout.editorTabCloseGlyph,
          color: hovering ? Color.theme.textPrimary : Color.theme.editorIcon)
      }
    }
    .frame(width: Theme.Layout.editorTabClose, height: Theme.Layout.editorTabClose)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.editorTabClose)
        .fill(hovering ? Color.theme.editorTabCloseHover : .clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { shell.requestClose(tab.id) }
  }
}

/// パンくず: 根からのディレクトリ › … › チップ ＋ ファイル名。ディレクトリはホバーで文字が上がり、押すと
/// ツリーのそのフォルダが開く（根の外は押せない）。
struct BreadcrumbView: View {
  let shell: EditorShellModel
  @Environment(\.chromeFontResolver) private var fontResolver

  private let separatorSize: CGFloat = 10

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      ForEach(shell.crumbs) { crumb in
        if crumb.id > 0 { separator }
        CrumbDirectory(crumb: crumb, shell: shell)
      }
      if !shell.crumbs.isEmpty { separator }
      if let name = shell.activeName, let chip = shell.activeChip {
        HStack(spacing: Theme.Space.tick) {
          FileChipView(chip: chip, size: Theme.Layout.editorChipSmall)
          fontResolver.text(name, base: Theme.Typography.editorBreadcrumb)
            .foregroundStyle(Color.theme.editorText)
        }
      }
      Spacer(minLength: 0)
    }
    .font(Font.theme.editorBreadcrumb)
    .foregroundStyle(Color.theme.textMuted)
    .lineLimit(1)
    .padding(.leading, Theme.Space.bar)
    .padding(.trailing, Theme.Space.beat)
    .frame(height: Theme.Layout.editorBreadcrumb)
    .clipped()
  }

  private var separator: some View {
    EditorGlyphView(
      glyph: EditorGlyphs.crumbChevron, size: separatorSize, color: Color.theme.editorTertiary)
  }
}

private struct CrumbDirectory: View {
  let crumb: EditorShellModel.Crumb
  let shell: EditorShellModel
  @State private var hovering = false
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    fontResolver.text(crumb.name, base: Theme.Typography.editorBreadcrumb)
      .foregroundStyle(
        hovering && crumb.directory != nil ? Color.theme.editorText : Color.theme.textMuted
      )
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture {
        if let directory = crumb.directory { shell.revealDirectory(directory) }
      }
  }
}
