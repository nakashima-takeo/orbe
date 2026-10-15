import SwiftUI

/// 列の頭（タブ行 28 → タブがあればパンくず 20）の SwiftUI ルート。器の中の別 root なので環境は
/// 明示注入する。タブが無いときはタブ行の帯だけ。
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

/// タブ行: 自然幅のタブ（文書のタブと diff のタブ）を横に並べ、溢れは横スクロール（スクローラー非表示・アクティブを
/// 可視位置へ）。焦点が diff のタブなら右端に見せ方の切り替え。
struct FileTabsView: View {
  let shell: EditorShellModel
  @Environment(\.colorScheme) private var scheme

  // 見本 EditorLayer.tsx のタブ行の地と下縁。
  private static let sunkAlpha = 0.22
  private static let hairlineAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
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
        if shell.showsDiffModes { DiffModesView(shell: shell) }
      }
      .frame(height: Theme.Layout.editorFileTabs)
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
    }
    .background(ink.sunk(Self.sunkAlpha))
  }
}

/// タブ 1 枚: チップ ＋ 名前（diff のタブは ＋ 種類の注記）＋ 右端の枠（未保存の ● か ×）。アクティブは淡い地と上縁
/// 1.5px——文書のタブは accent、diff のタブは注意の黄（design-system §5 のエディター面の例外）。仮のタブは名前を斜体に
/// し、地に斜線を敷く（アクティブなら淡い地の上）。押すと切り替え、2 回目の押下（ダブルクリック）で普通のタブにする——
/// 1 回目をダブルクリックの判定で待たせない。
struct FileTabView: View {
  let tab: EditorShellModel.FileTab
  let shell: EditorShellModel
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

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
        .italic(tab.isPreview)
        .font(Font.theme.editorFileTab)
        .foregroundStyle(tab.isActive ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
      if let kind = tab.diffKind {
        Text(l10n.string(kind == .workingTree ? .editorDiffWorkingTree : .editorDiffStaged))
          .italic(tab.isPreview)
          .font(Font.theme.editorDiffNote)
          .foregroundStyle(Color.theme.editorCaution)
          .lineLimit(1)
      }
      FileTabCloseSlot(tab: tab, tabHovered: hovering, shell: shell)
    }
    .padding(.leading, padLeading)
    .padding(.trailing, Theme.Layout.editorFileTabTrailing)
    .frame(height: Theme.Layout.editorFileTabs)
    .background {
      ZStack {
        if tab.isActive { ink.fill(Self.activeFillAlpha) }
        if tab.isPreview { PreviewHatch(isActive: tab.isActive) }
      }
    }
    .overlay(alignment: .top) {
      if tab.isActive {
        Rectangle()
          .fill(tab.diffKind == nil ? Color.theme.accentPrimary : Color.theme.editorCaution)
          .frame(height: accentBar)
      }
    }
    .overlay(alignment: .trailing) {
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(width: Theme.Stroke.hairline)
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { shell.activate(tab.id) }
    .simultaneousGesture(TapGesture(count: 2).onEnded { shell.pin(tab.id) })
  }
}

/// タブ行の右端の「インライン / 並列」。選んでいる項目は地を濃い字の色、字をアクティブのタブの字の色に反転する。
private struct DiffModesView: View {
  let shell: EditorShellModel
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Layout.editorDiffSegmentGap) {
      segment(.inline, .editorDiffInline)
      segment(.side, .editorDiffSide)
    }
    .padding(.horizontal, Theme.Layout.editorDiffSegmentInset)
  }

  private func segment(_ mode: EditorDiff.Mode, _ label: L10nKey) -> some View {
    let selected = shell.diffMode == mode
    return Text(l10n.string(label))
      .font(Font.theme.editorDiffSegment)
      .foregroundStyle(selected ? Color.theme.tabActiveText : Color.theme.textSecondary)
      .lineLimit(1)
      .padding(.horizontal, Theme.Layout.editorDiffSegmentPadX)
      .padding(.vertical, Theme.Layout.editorDiffSegmentPadY)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.editorDiffSegment)
          .fill(
            selected
              ? Color.theme.textPrimary
              : EditorInk(scheme).fill(Theme.Opacity.editorDiffSegmentIdle))
      )
      .contentShape(Rectangle())
      .onTapGesture { shell.selectDiffMode(mode) }
  }
}

/// 仮のタブの地の斜線（135°。線と周期はタブの左上から数えるので、タブの幅に依らず揃い、横スクロールでタブと一緒に動く）。
private struct PreviewHatch: View {
  let isActive: Bool

  var body: some View {
    let color = Color.theme.editorPreviewHatch.opacity(
      isActive ? Theme.Opacity.editorPreviewHatchActive : Theme.Opacity.editorPreviewHatchInactive)
    Canvas { context, size in
      let line = Theme.Stroke.editorPreviewHatch
      // 線は x + y = c（右上がり）。周期と線の太さは線に直交する向きで測る。
      let step = Theme.Layout.editorPreviewHatchPeriod * 2.squareRoot()
      var path = Path()
      var c = line / 2 * 2.squareRoot()
      while c < size.width + size.height {
        path.move(to: CGPoint(x: c, y: 0))
        path.addLine(to: CGPoint(x: c - size.height, y: size.height))
        c += step
      }
      context.stroke(path, with: .color(color), lineWidth: line)
    }
    .allowsHitTesting(false)
  }
}

/// タブの右端の枠に出すもの。VS Code のタブと同じく、アクティブは × を常に、それ以外はタブにポインタがあるときだけ
/// 出し、未保存は × 自体にポインタがあるときのほかは × の代わりに ● を出す。
private enum FileTabMark {
  case none
  case dirty
  case close

  init(tab: EditorShellModel.FileTab, tabHovered: Bool, closeHovered: Bool) {
    if tab.isDirty && !closeHovered {
      self = .dirty
    } else if tab.isActive || tabHovered || closeHovered {
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
      switch FileTabMark(tab: tab, tabHovered: tabHovered, closeHovered: hovering) {
      case .none: EmptyView()
      case .dirty:
        Circle()
          .fill(tab.isConflicted ? Color.theme.editorCaution : Color.theme.textPrimary)
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
