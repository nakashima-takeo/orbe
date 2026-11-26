import AppKit
import SwiftUI

/// 面の中の確認の中身——題・本文・確定のボタンの名前・VoiceOver のダイアログの名前。
struct EditorConfirmContent: Equatable {
  let title: String
  let message: String
  let confirmTitle: String
  let label: String
}

/// 面の中の確認の器——面の最前面に、幕とダイアログを出す確認の状態と、確定したときの処理を持つ。閉じ方は閉じたきっかけの型で
/// 表し、確定（`confirm`）のほかは、どのきっかけ（esc・「キャンセル」・画面や根が替わった・面が隠れた・フォーカスが外へ）も
/// キャンセル。器の状態を書くのは器だけで、host の見せ隠し・フォーカス・閉じ方の監視は、器を持つ pane が `onShow` /
/// `onClose` で受ける。
@MainActor @Observable
final class EditorConfirm {
  private(set) var content: EditorConfirmContent?
  @ObservationIgnored private var action: (() -> Void)?
  /// 出した（pane が host を見せ、フォーカスを移し、フォーカスの行き先の見張りを始める）。
  @ObservationIgnored var onShow: () -> Void = {}
  /// 閉じた（引数はきっかけ。pane が見張りをやめ、きっかけが求めればフォーカスを戻し、host を隠す）。
  @ObservationIgnored var onClose: (EditorDismissal) -> Void = { _ in }

  var isShown: Bool { content != nil }

  /// `content` の確認を出し、確定したら `action` を行う。既に確認が出ていれば、後から来た確認は出さず、その `action` も
  /// 行わない（破棄しない側に倒す）。
  func show(_ content: EditorConfirmContent, confirm action: @escaping () -> Void) {
    guard !isShown else { return }
    self.content = content
    self.action = action
    onShow()
  }

  /// キャンセルとして閉じる（確定の処理は行わない）。
  func close(_ dismissal: EditorDismissal) {
    guard isShown else { return }
    content = nil
    action = nil
    onClose(dismissal)
  }

  /// 確定する——閉じてから、確定の処理を行う。
  func confirm() {
    guard isShown, let action else { return }
    close(.owner)
    action()
  }
}

/// 面の中の確認の host。面の最前面に面いっぱいの枠で置き、出ている間だけ見せる。フォーカスはこの view が持ち、esc で
/// キャンセルし、ほかのキー（↵ を含む）とマウスの押下・スクロールは、ダイアログのボタンのほかは何もしない——幕の裏の
/// 端末にもテキスト面にも届けない。幕とダイアログは中の SwiftUI（→ `EditorConfirmRoot`）が描く。
final class EditorConfirmHost: NSView {
  let confirm: EditorConfirm
  private let hosting: EditorConfirmHosting

  init(confirm: EditorConfirm, root: EditorConfirmRoot) {
    self.confirm = confirm
    hosting = EditorConfirmHosting(rootView: root)
    super.init(frame: .zero)
    addSubview(hosting)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 中身の root を差し替える（窓の環境が変わった）。
  var root: EditorConfirmRoot {
    get { hosting.rootView }
    set { hosting.rootView = newValue }
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func layout() {
    super.layout()
    hosting.frame = bounds
  }

  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == "\u{1b}" { confirm.close(.escape) }
  }

  override func cancelOperation(_ sender: Any?) {
    confirm.close(.escape)
  }

  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}

/// 確認の中身の host。押してもフォーカスを取らない（フォーカスは外側の host が持ち続ける）。扱わない押下は外側の host へ
/// 渡る。
private final class EditorConfirmHosting: NSHostingView<EditorConfirmRoot> {
  override var acceptsFirstResponder: Bool { false }
}

/// 面の中の確認の SwiftUI ルート——面いっぱいの幕と、上端から 150・左右の中央のダイアログ（幅 430。面が狭ければ左右に
/// 12 を残す）。器の中の別 root なので環境は明示注入する。
struct EditorConfirmRoot: View {
  let confirm: EditorConfirm
  let localization: LocalizationStore
  let translucency: ChromeTranslucency

  var body: some View {
    ZStack(alignment: .top) {
      if let content = confirm.content {
        Color.theme.editorConfirmVeil
        EditorConfirmDialog(
          content: content, cancel: { confirm.close(.owner) }, confirm: confirm.confirm
        )
        .frame(maxWidth: Theme.Layout.editorConfirmWidth)
        .padding(.horizontal, Theme.Layout.editorConfirmInset)
        .padding(.top, Theme.Layout.editorConfirmTop)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.localization, localization)
    .environment(\.chromeTranslucency, translucency)
  }
}

/// 確認のダイアログ——ガラスの地・角丸 14 に、題・本文・右寄せのボタン列（「キャンセル esc」と、danger の地の確定）。確定は
/// クリックだけで行い、↵ では行わない。
struct EditorConfirmDialog: View {
  let content: EditorConfirmContent
  let cancel: () -> Void
  let confirm: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.editorConfirmRadius) {
      VStack(alignment: .leading, spacing: 0) {
        EditorConfirmText(
          text: content.title, font: Theme.Typography.editorConfirmTitle,
          lineHeight: Theme.Typography.editorConfirmTitleLineHeight, color: Color.theme.textPrimary)
        EditorConfirmText(
          text: content.message, font: Theme.Typography.editorConfirmMessage,
          lineHeight: Theme.Typography.editorConfirmMessageLineHeight,
          color: Color.theme.textSecondary
        )
        .padding(.top, Theme.Layout.editorConfirmMessageGap)
        HStack(spacing: Theme.Layout.editorConfirmButtonGap) {
          Spacer(minLength: 0)
          EditorLargeButton(
            title: l10n.string(.commonCancel), key: .text("esc"), ground: .neutral, action: cancel)
          EditorLargeButton(title: content.confirmTitle, ground: .danger, action: confirm)
        }
        .padding(.top, Theme.Layout.editorConfirmButtonsGap)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, Theme.Layout.editorConfirmPadTop)
      .padding(.horizontal, Theme.Layout.editorConfirmPadX)
      .padding(.bottom, Theme.Layout.editorConfirmPadBottom)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(content.label)
    .accessibilityAddTraits(.isModal)
  }
}

/// 行の高さ（字の大きさの倍率）を持つ文——行の間に加え、1 行目の上と最後の行の下にも、行の高さの余りの半分を置く（見本の
/// line-height と同じ置き方）。
private struct EditorConfirmText: View {
  let text: String
  let font: NSFont
  let lineHeight: CGFloat
  let color: Color

  var body: some View {
    let extra = font.extraLeading(lineHeight: lineHeight)
    Text(text)
      .font(Font(font as CTFont))
      .lineSpacing(extra)
      .foregroundStyle(color)
      .padding(.vertical, extra / 2)
  }
}
