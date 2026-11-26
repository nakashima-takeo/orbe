import SwiftUI

/// 上のバーの今の項目のボタンの形（高さ 26・角丸 7・地 `surfaceInk` .06 と 1px の枠 .05・末尾の ▾）。一覧の器を開いている間は
/// 地 .11。中身は今の項目の種類ごとの view。押してもフォーカスを求めない（上のバーの host は first responder を受けない）。
struct EditorItemButton<Label: View>: View {
  let isOpen: Bool
  let help: String
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  var body: some View {
    HStack(spacing: Theme.Layout.editorItemButtonGap) {
      label()
      EditorGlyphView(
        glyph: EditorGlyphs.chevronDown, size: Theme.Layout.editorItemButtonCaret,
        color: Color.theme.textMuted)
    }
    .lineLimit(1)
    .padding(.horizontal, Theme.Layout.editorItemButtonPadX)
    .frame(height: Theme.Layout.editorItemButton)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorItemButtonRadius)
        .fill(
          Color.theme.surfaceInk.opacity(
            isOpen ? Theme.Opacity.editorItemButtonOpen : Theme.Opacity.editorItemButtonFill))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.editorItemButtonRadius)
        .strokeBorder(
          Color.theme.surfaceInk.opacity(Theme.Opacity.editorItemButtonBorder),
          lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help)
    .accessibilityAddTraits(.isButton)
  }
}

/// 今のファイルのボタンの中身: 種別のチップ・親のパス（mono 12・muted）・名前（mono 12 semibold・primary。仮の文書は斜体）・
/// 印の丸（未保存は primary、「ディスクが変わった」は caution）。渡された幅に収まるいちばん広い姿を選ぶ——親のパスつき（名前は
/// 省略しない）、親のパスなし（名前は幅が無ければ省略する）の順。
struct EditorCurrentFileLabel: View {
  let file: EditorShellModel.CurrentFile

  var body: some View {
    ViewThatFits(in: .horizontal) {
      if !file.directory.isEmpty {
        HStack(spacing: Theme.Layout.editorItemButtonGap) {
          FileChipView(chip: file.chip)
          Text(file.directory)
            .font(Font.theme.editorItemButtonPath)
            .foregroundStyle(Color.theme.textMuted)
            .fixedSize()
          name(file.name).fixedSize(horizontal: true, vertical: false)
          dot
        }
      }
      HStack(spacing: Theme.Layout.editorItemButtonGap) {
        FileChipView(chip: file.chip)
        EditorReadableName(file.name) { name($0) }
        dot
      }
    }
  }

  private func name(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.editorItemButtonName)
      .italic(file.isPreview)
      .foregroundStyle(Color.theme.textPrimary)
      .truncationMode(.middle)
  }

  @ViewBuilder private var dot: some View {
    if let dot = EditorMarkDot(file.mark, size: Theme.Layout.editorItemDot) { dot }
  }
}

/// 幅が無ければ省略して縮む 1 行の名前。先頭の `prefixLength` 字（既定は 1 字）と「…」の幅（読める下限）より狭くならない
/// ——下限は、同じ描き方の見本（先頭の字と「…」）を見えない形で置いて測る（`TruncatingSlot` と同じ測り方）。下限より狭い幅を
/// 渡されても下限の幅を取り、はみ出した分は、置いた側の枠で切れる。
struct EditorReadableName<Content: View>: View {
  let text: String
  let prefixLength: Int
  let render: (String) -> Content

  init(
    _ text: String, prefixLength: Int = 1, @ViewBuilder render: @escaping (String) -> Content
  ) {
    self.text = text
    self.prefixLength = prefixLength
    self.render = render
  }

  var body: some View {
    EditorReadableNameLayout {
      render(text).lineLimit(1)
      render(String(text.prefix(prefixLength)) + "…").lineLimit(1).fixedSize().hidden()
    }
  }
}

/// 子 [本体, 見本]。幅は、本体が渡された幅で使う幅と、読める下限（本体の全幅と見本の幅の小さいほう）の大きいほう。
private struct EditorReadableNameLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let fits = content.sizeThatFits(proposal)
    return CGSize(width: max(fits.width, floor(subviews)), height: fits.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let width = max(proposal.width ?? bounds.width, floor(subviews))
    for subview in subviews {
      subview.place(
        at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: width, height: bounds.height))
    }
  }

  private func floor(_ subviews: Subviews) -> CGFloat {
    guard subviews.count == 2 else { return 0 }
    return min(
      subviews[0].sizeThatFits(.unspecified).width, subviews[1].sizeThatFits(.unspecified).width)
  }
}

/// 文書の印の丸（未保存は primary、「ディスクが変わった」は caution）。印の意味をツールチップと VoiceOver に出す。上のバーの今の
/// ファイルのボタンと diff の見出しが使う。
struct EditorMarkDot: View {
  private let isDiskChanged: Bool
  private let size: CGFloat
  @Environment(\.localization) private var l10n

  /// 印 `mark` の丸（丸を出さない印なら nil）。
  init?(_ mark: EditorItemListRow.Mark, size: CGFloat) {
    switch mark {
    case .unsaved: isDiskChanged = false
    case .diskChanged: isDiskChanged = true
    case .none, .close: return nil
    }
    self.size = size
  }

  var body: some View {
    let label = l10n.string(isDiskChanged ? .editorItemDiskChanged : .editorItemUnsaved)
    Circle().fill(isDiskChanged ? Color.theme.editorCaution : Color.theme.textPrimary)
      .frame(width: size, height: size)
      .help(label)
      .accessibilityLabel(label)
  }
}

/// 今の diff のボタンの中身: 状態の字（mono 10.5 semibold・色は左の列の行と同じ決まり。無ければ出さない）・ファイル名
/// （mono 12 semibold・primary。幅が無ければ省略する）。ディレクトリと印の丸は、すぐ下の差分の見出しに出ているので出さない。
struct EditorCurrentDiffLabel: View {
  let header: DiffFileHeader

  var body: some View {
    HStack(spacing: Theme.Layout.editorItemButtonGap) {
      if let badge = header.badge {
        Text(badge.label)
          .font(Font.theme.editorDiffHeaderBadge)
          .foregroundStyle(badge.color)
          .frame(width: Theme.Layout.editorDiffHeaderBadge)
      }
      EditorReadableName(header.name) { name in
        Text(name)
          .font(Font.theme.editorItemButtonName)
          .foregroundStyle(Color.theme.textPrimary)
          .truncationMode(.middle)
      }
    }
  }
}

/// 状態を示す札（「プレビュー」。sans 10.5・secondary・1px の枠 `surfaceInk` .2・角丸 4・余白 1 6）。一覧の行の札と同じ形。
struct EditorTag: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.editorTag)
      .foregroundStyle(Color.theme.textSecondary)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Layout.editorTagPadX)
      .padding(.vertical, Theme.Layout.editorTagPadY)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Layout.editorTagRadius)
          .strokeBorder(
            Color.theme.surfaceInk.opacity(Theme.Opacity.editorTag),
            lineWidth: Theme.Stroke.hairline)
      )
  }
}
