import AppKit
import SwiftUI

/// セグメント形ワークスペースタブ（TabBar・§5 Tab 契約）。
/// 非選択=地 tabSegBg・文字 textSecondary・状態色グリフ 12px。
/// 選択=地 textPrimary（前景色反転）・文字 tabActiveText・対テーマ状態色グリフ
/// （done の check 線のみ textPrimary）。タブ背景を状態色で塗らない。idle/nil はグリフ非表示。
/// `editing` のときはタイトルを裸の `TextField` へ差し替え、選択面のまま field editor でその場編集する
/// （Cmd+R インライン改名。SSOT・確定/取消・focus 駆動は app 層が握り、DS は与えられた状態を描くだけ）。
struct DSTab: View {
  let title: String
  var active: Bool = false
  /// タブ内集約状態の種別（nil で表示なし＝idle/無し）。
  var stateGlyph: AgentStateIcon.Kind?
  /// 状態グリフを上書きする SF Symbol 名（nil＝Glass 既定）。DS 層は env を読まず、解決は app 層が担う。
  var stateSymbol: String?
  var action: () -> Void = {}

  /// インライン改名の編集バリアント（app 層が駆動）。true でタイトルを `TextField` へ差し替える。
  var editing: Bool = false
  /// 編集テキストの SSOT（app 層 `StatusRowModel.editingText` と双方向バインド）。
  var editingText: Binding<String> = .constant("")
  /// focus 駆動トークン。app が `&+= 1` し、View が `.onChange` で field editor を first responder にする。
  var editFocusToken: Int = 0
  /// 空欄時に薄く見せる戻り先（派生タイトル②③）のプレビュー。
  var editPlaceholder: String = ""
  /// 確定（onSubmit＝IME 変換確定の Enter では発火しない）。
  var onSubmit: () -> Void = {}
  /// 取消（Esc・blur）。
  var onCancel: () -> Void = {}

  /// フォント割り当て（タブタイトルフォント・絵文字）。未注入（preview）は既定＝システム等幅＋Noto。
  @Environment(\.chromeFontResolver) private var fontResolver

  /// 編集 field の first responder 制御（`PaletteCard` と同じ focusToken 定石）。
  @FocusState private var focused: Bool
  /// 一度 focus を得たか。初期の false 遷移を blur=取消として誤検知しないためのガード。
  @State private var didFocus = false

  /// 状態グリフの描画サイズ（SegmentGlyph）。
  private let glyphSize: CGFloat = 12

  /// 選択面（地 textPrimary・文字 tabActiveText）。編集タブは常に選択面で描く。
  private var selected: Bool { active || editing }

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      if let stateGlyph {
        StatusGlyphView(
          kind: stateGlyph, size: glyphSize, workingStroke: 1.6,
          color: selected ? stateGlyph.inverseColor : nil,
          checkStroke: selected ? Color.theme.textPrimary : nil,
          symbol: stateSymbol)
      }
      if editing {
        titleField
      } else {
        Text(fontResolver.attributed(title, base: fontResolver.tabTitleFont))
          .font(Font(fontResolver.tabTitleFont as CTFont))
          .foregroundStyle(selected ? Color.theme.tabActiveText : Color.theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(maxWidth: Chrome.tabMaxWidth, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.xs)
        .fill(selected ? Color.theme.textPrimary : Color.theme.tabSegBg)
    )
    .contentShape(Rectangle())
    // 編集中は tap を付けない（app 層も drag を付けない＝ジェスチャ排他が構造的に成立する）。
    .modifier(TapUnless(disabled: editing, action: action))
  }

  /// 選択面に載せる裸の改名 field（§5 Tab 選択面・挿入点は accentPrimary）。
  private var titleField: some View {
    TextField("", text: editingText)
      .textFieldStyle(.plain)
      .font(Font(fontResolver.tabTitleFont as CTFont))
      .foregroundStyle(Color.theme.tabActiveText)
      .tint(Color.theme.accentPrimary)  // 挿入点（カーソル）・選択ハイライト色
      .lineLimit(1)
      .focused($focused)
      // 空欄時のみ戻り先の派生名を muted で薄く見せる（IME 変換中は抑制）。
      .imePlaceholder(
        editPlaceholder, showWhenEmpty: editingText.wrappedValue.isEmpty, focused: focused,
        font: Font(fontResolver.tabTitleFont as CTFont), color: Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      // 確定＝onSubmit（IME 変換確定の Enter では発火しない＝誤爆しない）。
      .onSubmit(onSubmit)
      .onKeyPress(.escape) {
        onCancel(); return .handled
      }
      // 描画後に field editor へ first responder を移し、現在名を全選択して開く（打てば置換）。
      .onChange(of: editFocusToken, initial: true) { focused = true }
      .onChange(of: focused) { _, now in
        if now { didFocus = true } else if didFocus { onCancel() }  // blur=取消（初期 false は無視）
      }
      // focus 確定後に field editor を全選択する（SwiftUI の @FocusState 反映後に走らせる）。
      .background(FieldEditorSelectAll(token: editFocusToken))
  }
}

/// 編集でないときだけ `onTapGesture` を付ける薄い modifier（編集タブでは tap を発火させない）。
private struct TapUnless: ViewModifier {
  let disabled: Bool
  let action: () -> Void
  func body(content: Content) -> some View {
    if disabled { content } else { content.onTapGesture(perform: action) }
  }
}

/// focus トークンが進んだら、その tick 後に field editor（first responder の `NSTextView`）を全選択する。
/// SwiftUI の `TextField` は「focus 時に全選択」を直接持たないため、field editor へ降りて `selectAll` する。
private struct FieldEditorSelectAll: NSViewRepresentable {
  let token: Int
  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ nsView: NSView, context: Context) {
    guard token != context.coordinator.lastToken else { return }
    context.coordinator.lastToken = token
    // @FocusState の反映で field editor が first responder になった後に全選択する。
    DispatchQueue.main.async {
      (nsView.window?.firstResponder as? NSTextView)?.selectAll(nil)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator { var lastToken = Int.min }
}

#Preview("DSTab") {
  HStack(spacing: Chrome.tabGap) {
    DSTab(title: "src/renderer", active: true, stateGlyph: .working)
    DSTab(title: "libghostty", stateGlyph: .waiting)
    DSTab(title: "tests")
    DSTab(title: "docs/spec", stateGlyph: .done)
  }
  .padding(Chrome.tabRowPad)
  .frame(height: Chrome.tabRowHeight)
  .background(Color.theme.tabRowBg)
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgBase)
}
