import SwiftUI

/// 列の頭（ファイルタブ行 34 → 文書があればパンくず 22）の SwiftUI ルート。器の中の別 root なので環境は
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

/// タブ 1 枚: チップ ＋ 名前 ＋ 未保存ドット（衝突中は modified 黄）＋ ×（幅は常に確保し、ホバーでだけ見える）。
/// アクティブは淡い地と上縁 1.5px の accent（design-system §5 のエディター面の例外）。
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
  private let padX: CGFloat = 10
  private let dotSize: CGFloat = 7
  private let closeGlyph: CGFloat = 10
  private let closeHit: CGFloat = 14

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: Theme.Space.note) {
      FileChipView(chip: tab.chip)
      fontResolver.text(tab.name, base: Theme.Typography.editorFileTab)
        .font(Font.theme.editorFileTab)
        .foregroundStyle(tab.isActive ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
      if tab.isDirty {
        Circle()
          .fill(tab.isConflicted ? Color.theme.editorModified : Color.theme.textPrimary)
          .frame(width: dotSize, height: dotSize)
          .padding(.leading, Theme.Space.hair)
      }
      EditorGlyphView(glyph: EditorGlyphs.close, size: closeGlyph, color: Color.theme.editorIcon)
        .frame(width: closeHit, height: closeHit)
        .opacity(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { shell.requestClose(tab.id) }
    }
    .padding(.horizontal, padX)
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
