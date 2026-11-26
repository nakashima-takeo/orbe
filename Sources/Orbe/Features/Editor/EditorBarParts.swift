import SwiftUI

/// 上のバーの区切り線（1×16・hairline .15・左右 6）。右の部品の一部として、その部品の中に置く（部品が落ちれば一緒に落ちる）。
struct EditorBarSeparator: View {
  @Environment(\.colorScheme) private var scheme

  private static let alpha = 0.15
  private static let height: CGFloat = 16

  var body: some View {
    Rectangle().fill(EditorInk(scheme).hairline(Self.alpha))
      .frame(width: Theme.Stroke.hairline, height: Self.height)
      .padding(.horizontal, Theme.Space.note)
  }
}

/// 上のバーの中ほどの札（高さ 26・角丸 7）。素の姿は地なし・mono 12・左右 8・間 6、地つきの変種（同期）は地 ink .08・
/// sans 12・左右 9・間 7。字は primary。中身は載せる側が渡す。ツールチップと VoiceOver の名前は `help`。`action` を渡せば
/// ボタンで、押せない間は disabled に薄める。押してもフォーカスを求めない。`action` を省けば表示だけの札で、ボタンの特性も
/// 押下の働きも持たない。
struct EditorBarChip<Content: View>: View {
  enum Style {
    case plain
    case filled
  }

  var style = Style.plain
  var isEnabled = true
  let help: String
  var action: (() -> Void)?
  @ViewBuilder let content: () -> Content

  var body: some View {
    if let action {
      face
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { action() } }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
    } else {
      face
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
  }

  private var face: some View {
    HStack(
      spacing: style == .filled
        ? Theme.Layout.editorBarChipFilledGap : Theme.Layout.editorBarChipGap
    ) {
      content()
    }
    .font(style == .filled ? Font.theme.editorBarChipFilled : Font.theme.editorBarChip)
    .foregroundStyle(Color.theme.textPrimary)
    .lineLimit(1)
    .padding(
      .horizontal,
      style == .filled ? Theme.Layout.editorBarChipFilledPadX : Theme.Layout.editorBarChipPadX
    )
    .frame(height: Theme.Layout.editorBarChip)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorBarChipRadius)
        .fill(
          style == .filled
            ? Color.theme.surfaceInk.opacity(Theme.Opacity.editorBarChipFill) : .clear)
    )
    .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
  }
}

/// 上のバーの 26 角のアイコンのボタン（角丸 7・印 14・印 secondary）。押された姿は地 ink .08・印 primary。押しても
/// フォーカスを求めない。ツールチップと VoiceOver の名前は `help`。
struct EditorBarIconButton: View {
  let glyph: EditorGlyphs.Glyph
  var isPressed = false
  let help: String
  let action: () -> Void

  var body: some View {
    EditorGlyphView(
      glyph: glyph, size: Theme.Layout.editorBarIconGlyph,
      color: isPressed ? Color.theme.textPrimary : Color.theme.textSecondary
    )
    .frame(width: Theme.Layout.editorBarIconButton, height: Theme.Layout.editorBarIconButton)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorBarIconButtonRadius)
        .fill(
          isPressed ? Color.theme.surfaceInk.opacity(Theme.Opacity.editorBarIconPressed) : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help)
    .accessibilityAddTraits(.isButton)
  }
}

/// 上のバーの右端の主な操作のボタン（コミット・レビュー）。高さ 26・角丸 7・間 7・左 11 右 6・地 accent .24・枠 accent .6・
/// sans 12 semibold・字 primary・末尾の ▾ は accentBright。開いている間は地 accent .36。名前の後ろに、固定の添え（`badge`）と
/// 譲る添え書き（`detail`。`actionDetail` で譲る）を置ける。左に 12 の余白（案内との間）を持つ。押せない間は disabled に
/// 薄める。押してもフォーカスを求めない。ツールチップは `help`、VoiceOver の名前は `accessibilityName`（省けば `help`）。
/// 枠は、上のバーの座標で `editorBarActionFrame` へ知らせ、消えたら nil を知らせる（外の押下の判定の入力）。
struct EditorBarActionButton<Badge: View, Detail: View>: View {
  let title: String
  var isOpen = false
  var isEnabled = true
  let help: String
  var accessibilityName: String?
  let action: () -> Void
  @ViewBuilder let badge: () -> Badge
  @ViewBuilder let detail: () -> Detail
  @Environment(\.editorBarActionFrame) private var reportFrame
  /// 枠を知らせるときの、このボタンの印。
  @State private var frameID = UUID()

  var body: some View {
    ViewThatFits(in: .horizontal) {
      face(showsDetail: true)
      face(showsDetail: false)
    }
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(EditorBarRoot.space))
    } action: {
      reportFrame(frameID, $0)
    }
    .onDisappear { reportFrame(frameID, nil) }
    .padding(.leading, Theme.Layout.editorBarActionLead)
    .editorBarPart(.trailing, grows: .actionDetail)
  }

  private func face(showsDetail: Bool) -> some View {
    HStack(spacing: Theme.Layout.editorBarActionGap) {
      Text(title)
        .font(Font.theme.editorBarAction)
        .foregroundStyle(Color.theme.textPrimary)
      if showsDetail { detail() }
      badge()
      EditorGlyphView(
        glyph: EditorGlyphs.chevronDown, size: Theme.Layout.editorItemButtonCaret,
        color: Color.theme.accentBright)
    }
    .lineLimit(1)
    .fixedSize()
    .padding(.leading, Theme.Layout.editorBarActionPadLeading)
    .padding(.trailing, Theme.Layout.editorBarActionPadTrailing)
    .frame(height: Theme.Layout.editorBarAction)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorBarActionRadius)
        .fill(
          Color.theme.accentPrimary.opacity(
            isOpen ? Theme.Opacity.editorBarActionOpen : Theme.Opacity.editorBarActionFill))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.editorBarActionRadius)
        .strokeBorder(
          Color.theme.accentPrimary.opacity(Theme.Opacity.editorBarActionBorder),
          lineWidth: Theme.Stroke.hairline)
    )
    .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    .contentShape(Rectangle())
    .onTapGesture { if isEnabled { action() } }
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityName ?? help)
    .accessibilityAddTraits(.isButton)
  }
}

extension EditorBarActionButton where Badge == EmptyView, Detail == EmptyView {
  init(
    title: String, isOpen: Bool = false, isEnabled: Bool = true, help: String,
    accessibilityName: String? = nil, action: @escaping () -> Void
  ) {
    self.init(
      title: title, isOpen: isOpen, isEnabled: isEnabled, help: help,
      accessibilityName: accessibilityName, action: action,
      badge: { EmptyView() }, detail: { EmptyView() })
  }
}

extension EditorBarActionButton where Badge == EmptyView {
  init(
    title: String, isOpen: Bool = false, isEnabled: Bool = true, help: String,
    accessibilityName: String? = nil, action: @escaping () -> Void,
    @ViewBuilder detail: @escaping () -> Detail
  ) {
    self.init(
      title: title, isOpen: isOpen, isEnabled: isEnabled, help: help,
      accessibilityName: accessibilityName, action: action,
      badge: { EmptyView() }, detail: detail)
  }
}

extension EditorBarActionButton where Detail == EmptyView {
  init(
    title: String, isOpen: Bool = false, isEnabled: Bool = true, help: String,
    accessibilityName: String? = nil, action: @escaping () -> Void,
    @ViewBuilder badge: @escaping () -> Badge
  ) {
    self.init(
      title: title, isOpen: isOpen, isEnabled: isEnabled, help: help,
      accessibilityName: accessibilityName, action: action,
      badge: badge, detail: { EmptyView() })
  }
}

private struct EditorBarActionFrameKey: EnvironmentKey {
  static let defaultValue: (UUID, CGRect?) -> Void = { _, _ in }
}

extension EnvironmentValues {
  /// 右端の主な操作のボタンの枠（上のバーの座標）を、ボタンごとの印と一緒に受け取る閉包。ボタンが消えたら枠は nil。上のバーの
  /// 根が pane への知らせを配る。
  var editorBarActionFrame: (UUID, CGRect?) -> Void {
    get { self[EditorBarActionFrameKey.self] }
    set { self[EditorBarActionFrameKey.self] = newValue }
  }
}
