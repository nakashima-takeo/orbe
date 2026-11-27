import AppKit
import SwiftUI

/// 1 行の入力欄の枠（デザインの見本の `.fl`・`.fnd`・`.sf`）。左から虫眼鏡・中身・右の添え物（件数やオプションのボタン）を
/// 並べ、地 `surfaceInk` .055・角丸 7 を描き、フォーカスがある間は内側に `accent.primary` .55 の枠を足す。入力の view と、
/// フォーカスの状態とキーの扱いは使う側が持つ。枠の中のどこを押しても（虫眼鏡・余白・件数の文の上も）、中の入力欄に
/// フォーカスを渡す（`EditorFieldFocusTarget`）——入力欄そのものと、添え物のボタンを押したときは、それぞれの働きのまま。
struct EditorFieldFrame<Content: View, Accessory: View>: View {
  let height: CGFloat
  let isFocused: Bool
  @ViewBuilder let content: () -> Content
  @ViewBuilder let accessory: () -> Accessory
  @State private var focusTarget = EditorFieldFocusTarget()

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
    // 押下の受け手は、地・フォーカスの枠線・中身をすべて含むいちばん外側に 1 つ置く——フォーカスの有無で、縁の上の押下の
    // 受け手が替わらない。
    .contentShape(shape)
    .onTapGesture { focusTarget.focus() }
    .environment(\.editorFieldFocusTarget, focusTarget)
  }
}

/// 入力欄の枠が押されたときに、枠の中の入力欄へフォーカスを渡す口。枠が持って環境で中身へ渡し、入力欄（`EditorTextField`）が
/// 自分を載せる。
@MainActor
final class EditorFieldFocusTarget {
  weak var field: NSTextField?

  /// 中の入力欄にフォーカスが無ければ first responder にする（AppKit が全選択する）。在れば触らない（打っている位置を保つ）。
  func focus() {
    guard let field, field.currentEditor() == nil, let window = field.window else { return }
    window.makeFirstResponder(field)
  }
}

private struct EditorFieldFocusTargetKey: EnvironmentKey {
  static let defaultValue: EditorFieldFocusTarget? = nil
}

extension EnvironmentValues {
  /// 入力欄の枠が中身へ渡す、フォーカスを渡す口（枠の外では nil）。
  var editorFieldFocusTarget: EditorFieldFocusTarget? {
    get { self[EditorFieldFocusTargetKey.self] }
    set { self[EditorFieldFocusTargetKey.self] = newValue }
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
