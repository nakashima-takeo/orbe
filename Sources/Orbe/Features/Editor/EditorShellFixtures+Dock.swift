#if DEBUG
  import AppKit
  import SwiftUI

  /// 上のバーの右下の置き場の仮の中身——入力欄 1 つとボタンを持つポップアップの中身（載せる側）と、失敗の札 2 枚。gallery が
  /// 置き場の姿を、flow が本物の面で開閉を撮る。
  extension EditorShellFixtures {
    /// ポップアップの中身を載せる側。入力欄は「❯」の後ろの伸びるメッセージ欄（sans 12.5・行の高さ 20・1 行で高さ 30）で、
    /// esc で器に閉じるよう頼む。ボタンと ⌘↵ は
    /// 「載せる側」のきっかけで閉じる。起きたこと（開いた回数・閉じる直前のきっかけ・扱った ⌘ つきのキー）を記録する。
    @MainActor final class DockPopupOwner: EditorPopupOwner {
      private weak var popup: EditorPopup?
      /// 地の部品に渡す色（縁・上側・外の光）。
      var tint: Color?
      private(set) var openCount = 0
      private(set) var closings: [EditorDismissal] = []
      private(set) var keys: [String] = []
      /// 入力欄（開閉をまたいで同じ欄を使う）。
      let field = MessageTextView(
        metrics: .init(
          font: .systemFont(ofSize: 12.5), height: 30, lineHeight: 20, leading: 0, trailing: 0))
      private let scroll = MessageScrollView()
      /// 入力欄へフォーカスを入れる頼み（欄が窓に載っていなければ、載ったときに当てる）。
      private var wantsFocus = false

      init(popup: EditorPopup?, tint: Color? = nil) {
        self.popup = popup
        self.tint = tint
        field.placeholder = "メッセージ"
        field.onEscape = { [weak self] in self?.popup?.close(.escape) }
        field.onWindow = { [weak self] in self?.applyFocus() }
        scroll.documentView = field
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        field.autoresizingMask = [.width]
      }

      func popupContent() -> AnyView {
        let scroll = scroll
        let field = field
        let commit: () -> Void = { [weak self] in self?.popup?.close(.owner) }
        return AnyView(
          EditorPopupGround(tint: tint) {
            HStack(alignment: .top, spacing: 9) {
              Text("❯")
                .font(Font.theme.editorBarAction)
                .foregroundStyle(Color.theme.accentBright)
                .frame(height: Theme.Layout.editorLargeButton)
              DockField(scroll: scroll, field: field)
              EditorLargeButton(
                title: "コミット", key: .glyph(EditorGlyphs.returnKey), ground: .accent,
                action: commit)
            }
            .padding(.leading, 14)
            .padding([.top, .bottom, .trailing], 8)
          })
      }

      func popupDidOpen() {
        openCount += 1
        wantsFocus = true
        applyFocus()
      }

      func popupWillClose(_ dismissal: EditorDismissal) {
        field.confirmComposition()
        closings.append(dismissal)
      }

      func popupKeyEquivalent(_ event: NSEvent) -> Bool {
        keys.append(event.charactersIgnoringModifiers ?? "")
        guard event.charactersIgnoringModifiers == "\r" else { return false }
        popup?.close(.owner)
        return true
      }

      private func applyFocus() {
        guard wantsFocus, let window = field.window else { return }
        wantsFocus = false
        window.makeFirstResponder(field)
      }
    }

    /// 失敗の札 2 枚（長い文は折り返す）。× は何もしない。
    @MainActor static var dockCards: some View {
      Group {
        EditorFailureCard(
          text:
            "コミットに失敗しました: 競合が残っています。競合を解決し、そのファイルをステージしてからコミットしてください。"
            + "（error: Committing is not possible because you have unmerged files.）",
          dismiss: {})
        EditorFailureCard(text: "プッシュに失敗しました: リモートに接続できません。", dismiss: {})
      }
    }

    /// 置き場の姿——ポップアップ（`owner` があれば）と札（`cards` が真なら）を、幅 620・高さ `height` の置き場に並べる。
    /// 下に本体の代わりの地を敷く。
    @MainActor static func dock(owner: DockPopupOwner?, cards: Bool, height: CGFloat) -> some View {
      EditorDockStack {
        if let owner { owner.popupContent() }
      } cards: {
        if cards { dockCards }
      }
      .frame(width: Theme.Layout.editorDockWidth, height: height)
      .padding(EditorDockRoot.margin)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }

    /// 仮の中身の入力欄（中身の行の高さに合わせる。1 行で 30、10 行まで。渡された高さを上限にし、越える分は欄の中で
    /// スクロールする）。
    private struct DockField: NSViewRepresentable {
      let scroll: NSScrollView
      let field: MessageTextView

      func makeNSView(context: Context) -> NSScrollView { scroll }

      func updateNSView(_ scroll: NSScrollView, context: Context) {}

      func sizeThatFits(
        _ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context
      ) -> CGSize? {
        let width = proposal.width ?? scroll.frame.width
        let height = field.fittingHeight(width: width, maxLines: ScmMessageField.maxLines)
        return CGSize(width: width, height: min(height, proposal.height ?? height))
      }
    }
  }
#endif
