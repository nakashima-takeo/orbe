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
/// 印の丸（未保存は primary、「ディスクが変わった」は caution）。`showsPath` が偽なら親のパスを落とす。`fitsName` が偽なら
/// 名前を省略して縮める（上のバーが狭いとき）。
struct EditorCurrentFileLabel: View {
  let file: EditorShellModel.CurrentFile
  let showsPath: Bool
  let fitsName: Bool

  var body: some View {
    HStack(spacing: Theme.Layout.editorItemButtonGap) {
      FileChipView(chip: file.chip)
      if showsPath, !file.directory.isEmpty {
        Text(file.directory)
          .font(Font.theme.editorItemButtonPath)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
      }
      Text(file.name)
        .font(Font.theme.editorItemButtonName)
        .italic(file.isPreview)
        .foregroundStyle(Color.theme.textPrimary)
        .truncationMode(.middle)
        .fixedSize(horizontal: fitsName, vertical: false)
      if let dot = EditorMarkDot(file.mark, size: Theme.Layout.editorItemDot) { dot }
    }
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
/// （mono 12 semibold・primary）。ディレクトリと印の丸は、すぐ下の差分の見出しに出ているので出さない。`fitsName` が偽
/// なら名前を省略して縮める（上のバーが狭いとき）。
struct EditorCurrentDiffLabel: View {
  let header: DiffFileHeader
  let fitsName: Bool

  var body: some View {
    HStack(spacing: Theme.Layout.editorItemButtonGap) {
      if let badge = header.badge {
        Text(badge.label)
          .font(Font.theme.editorDiffHeaderBadge)
          .foregroundStyle(badge.color)
          .frame(width: Theme.Layout.editorDiffHeaderBadge)
      }
      Text(header.name)
        .font(Font.theme.editorItemButtonName)
        .foregroundStyle(Color.theme.textPrimary)
        .truncationMode(.middle)
        .fixedSize(horizontal: fitsName, vertical: false)
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
