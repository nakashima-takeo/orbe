import AppKit
import SwiftUI

/// ブラウザ初回起動時（未遷移時）に外部通信せず表示する空画面。
/// 背景は常に不透明度 100% の `Theme.Color.bgBase`（`ChromeTranslucency` 非適用）。
struct BrowserEmptyView: View {
  let localization: LocalizationStore

  var body: some View {
    VStack(spacing: Theme.Space.note) {
      Text(localization.string(.browserEmptyTitle))
        .font(Font.theme.editorEmptyTitle)
        .foregroundStyle(Color.theme.textSecondary)
      Text(localization.string(.browserEmptyLead))
        .font(Font.theme.editorEmptyText)
        .foregroundStyle(Color.theme.textMuted)
      VStack(spacing: Theme.Space.note) {
        shortcutRow(localization.string(.browserEmptyShortcutClose), key: "⌘B")
        shortcutRow(localization.string(.browserEmptyShortcutReload), key: "⌘R")
      }
      .padding(.top, Theme.Space.step)
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, Theme.Space.bar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 60)
    .background(Color.theme.bgBase)
  }

  private func shortcutRow(_ label: String, key: String) -> some View {
    HStack(spacing: Theme.Space.step) {
      Text(label)
        .font(Font.theme.editorEmptyText)
        .foregroundStyle(Color.theme.textMuted)
      EditorKeyCap(content: .text(key))
    }
  }
}

/// 空画面の host。クリックは `BrowserLayerView` が受けて焦点を取る。
final class BrowserEmptyHost: NSHostingView<BrowserEmptyView> {
  override var acceptsFirstResponder: Bool { false }
}
