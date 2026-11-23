import SwiftUI

/// 1 行の入力欄の枠（デザインの見本の `.fl`・`.fnd`・`.sf`）。左から虫眼鏡・中身・右の添え物（件数やオプションのボタン）を
/// 並べ、地 `surfaceInk` .055・角丸 7 を描き、フォーカスがある間は内側に `accent.primary` .55 の枠を足す。入力の view と、
/// フォーカスの状態（`@FocusState` など）とキーの扱いは使う側が持ち、ここは形だけを持つ。
struct EditorFieldFrame<Content: View, Accessory: View>: View {
  let height: CGFloat
  let isFocused: Bool
  @ViewBuilder let content: () -> Content
  @ViewBuilder let accessory: () -> Accessory

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Layout.editorFieldRadius)
    HStack(spacing: Theme.Layout.editorFieldGap) {
      EditorGlyphView(
        glyph: EditorGlyphs.magnifier, size: Theme.Layout.editorFieldGlyph,
        color: Color.theme.textMuted)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
      accessory()
    }
    .padding(.leading, Theme.Layout.editorFieldPadLeading)
    .padding(.trailing, Theme.Layout.editorFieldPadTrailing)
    .frame(height: height)
    .background(shape.fill(Color.theme.surfaceInk.opacity(Theme.Opacity.editorFieldFill)))
    .overlay {
      if isFocused {
        shape.strokeBorder(
          Color.theme.accentPrimary.opacity(Theme.Opacity.editorFieldFocus),
          lineWidth: Theme.Layout.editorFieldFocusStroke)
      }
    }
  }
}

extension EditorFieldFrame where Accessory == EmptyView {
  init(height: CGFloat, isFocused: Bool, @ViewBuilder content: @escaping () -> Content) {
    self.init(height: height, isFocused: isFocused, content: content, accessory: { EmptyView() })
  }
}

#if DEBUG
  enum EditorFieldFrameFixtures {
    /// 高さ 26 と 28 のそれぞれで、フォーカスの有無と添え物の有無を並べる。gallery が dark / light を撮る。
    @MainActor static func gallery() -> some View {
      VStack(alignment: .leading, spacing: 12) {
        ForEach([CGFloat(26), 28], id: \.self) { height in
          HStack(spacing: 12) {
            EditorFieldFrame(height: height, isFocused: false) { placeholder("ファイルを絞り込む") }
            EditorFieldFrame(height: height, isFocused: true) { value("Tree") }
            EditorFieldFrame(height: height, isFocused: false) {
              value("isEditorOpen")
            } accessory: {
              count("2/3")
            }
            EditorFieldFrame(height: height, isFocused: true) {
              value("isEditorOpen")
            } accessory: {
              count("2/3")
            }
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
    }

    @MainActor private static func placeholder(_ text: String) -> some View {
      Text(text).font(Font.theme.editorSearchField).foregroundStyle(Color.theme.editorTertiary)
    }

    @MainActor private static func value(_ text: String) -> some View {
      Text(text).font(Font.theme.editorSearchField).foregroundStyle(Color.theme.textPrimary)
    }

    @MainActor private static func count(_ text: String) -> some View {
      Text(text)
        .font(Font.theme.editorBarHint)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.trailing, Theme.Space.note)
    }
  }

  #Preview("EditorFieldFrame") {
    EditorFieldFrameFixtures.gallery().frame(width: 960, height: 120)
  }
#endif
