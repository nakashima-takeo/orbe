import AppKit
import SwiftUI

/// 36px ブラウザツールバー（下端 hairline 1pt を含む）。
/// 左から サイドバー開閉・戻る・進む・再読込/停止・URL 欄（クリックでインライン編集）・全面 Peek ピル・全面⇄右シート切替。
/// 背景（`barGround`）は `BrowserLayerView` が常に 100% 不透明で塗り、非フォーカス時は子要素だけを 0.68 へ落ち着かせる。
struct BrowserBarRoot: View {
  @Bindable var model: BrowserToolbarModel
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    VStack(spacing: 0) {
      toolbarRow
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Layout.browserBar - Theme.Stroke.hairline)
        .clipped()

      Rectangle()
        .fill(Color.theme.browserBarBorder)
        .frame(height: Theme.Stroke.hairline)
    }
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  private var toolbarRow: some View {
    BrowserToolbarLayout(
      spacing: Theme.Layout.browserBarGap,
      urlMarginX: Theme.Layout.browserURLMarginX,
      urlPeekMinWidth: Theme.Layout.browserURLPeekMinWidth
    ) {
      BrowserIconButton(
        glyph: BrowserGlyphs.sidebar,
        isEnabled: true,
        isActive: model.isSidebarOpen,
        tooltip: localization.string(.browserBarToggleSidebar),
        action: model.onToggleSidebar
      )
      BrowserIconButton(
        glyph: BrowserGlyphs.back,
        isEnabled: model.canGoBack,
        isActive: false,
        tooltip: localization.string(.browserBarBack),
        action: model.onBack
      )
      BrowserIconButton(
        glyph: BrowserGlyphs.forward,
        isEnabled: model.canGoForward,
        isActive: false,
        tooltip: localization.string(.browserBarForward),
        action: model.onForward
      )
      BrowserIconButton(
        glyph: model.isLoading ? BrowserGlyphs.stop : BrowserGlyphs.reload,
        isEnabled: true,
        isActive: false,
        tooltip: localization.string(model.isLoading ? .browserBarStop : .browserBarReload),
        action: model.onReloadOrStop
      )
      BrowserURLBar(model: model, localization: localization)
        .browserToolbarURL()
      if model.mode == .full && model.isPeeking {
        BrowserFullPeekPill(underlay: model.peekUnderlay, localization: localization)
          .browserToolbarPeekPill()
      }
      BrowserIconButton(
        glyph: BrowserGlyphs.sheetToggle,
        isEnabled: true,
        isActive: model.mode == .sheet,
        tooltip: localization.string(
          model.mode == .sheet ? .browserBarSwitchToFull : .browserBarSwitchToSheet),
        action: model.onToggleFull
      )
    }
    .padding(.leading, Theme.Layout.browserBarLeading)
    .padding(.trailing, Theme.Layout.browserBarTrailing)
    .frame(height: Theme.Layout.browserBar - Theme.Stroke.hairline)
    .opacity(model.isInteractiveFocused ? 1 : Theme.Opacity.browserBarInactive)
    .animation(.easeOut(duration: Theme.Motion.quick), value: model.isInteractiveFocused)
  }
}

/// 26×26 のモノクロームアイコンボタン。押してもフォーカスを奪わず、アクション側でブラウザ焦点へ揃える。
private struct BrowserIconButton: View {
  let glyph: BrowserGlyphs.Glyph
  let isEnabled: Bool
  let isActive: Bool
  let tooltip: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    BrowserGlyphView(
      glyph: glyph,
      size: Theme.Layout.browserIconSize,
      color: (isActive || isHovered) && isEnabled
        ? Color.theme.textPrimary : Color.theme.textSecondary
    )
    .frame(width: Theme.Layout.browserIconButton, height: Theme.Layout.browserIconButton)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserIconButtonRadius)
        .fill(backgroundColor)
    )
    .opacity(isEnabled ? 1 : Theme.Opacity.browserButtonDisabled)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture {
      guard isEnabled else { return }
      action()
    }
    .help(tooltip)
  }

  private var backgroundColor: Color {
    guard isEnabled else { return .clear }
    if isActive {
      return Color.theme.surfaceInk.opacity(Theme.Opacity.browserButtonActive)
    }
    if isHovered {
      return Color.theme.surfaceInk.opacity(Theme.Opacity.browserButtonHover)
    }
    return .clear
  }
}

/// URL 欄。通常時は HTTPS 鍵＋ホスト/パス 2 トーン表示、クリックで `BrowserInlineTextField` インライン編集へ切り替える。
/// 底面に読込進捗バーを重ねる。
private struct BrowserURLBar: View {
  @Bindable var model: BrowserToolbarModel
  let localization: LocalizationStore
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Layout.browserURLGap) {
      if !model.isEditingURL, model.displayURL?.isSecure == true {
        BrowserGlyphView(
          glyph: BrowserGlyphs.lock,
          size: Theme.Layout.browserLockIconSize,
          color: Color.theme.textMuted)
      }
      if model.isEditingURL {
        BrowserInlineTextField(
          text: $model.editingText,
          placeholder: localization.string(.browserBarURLPlaceholder),
          font: Theme.Typography.browserURL,
          focusToken: model.editSessionToken,
          selectAllOnFocus: true,
          canFocus: { model.isEditingURL },
          onCommit: model.onCommitURL,
          onCancel: model.onCancelURL,
          onBlur: model.onBlurURL
        )
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      } else {
        displayLabel
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.leading, Theme.Layout.browserURLPadLeading)
    .padding(.trailing, Theme.Layout.browserURLPadTrailing)
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .frame(height: Theme.Layout.browserURLHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserURLRadius)
        .fill(
          Color.theme.surfaceInk.opacity(
            model.isEditingURL || isHovered
              ? Theme.Opacity.browserURLFillHover : Theme.Opacity.browserURLFill))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserURLRadius)
        .strokeBorder(
          model.isEditingURL
            ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserURLFocusBorder)
            : Color.theme.surfaceInk.opacity(Theme.Opacity.browserURLBorder),
          lineWidth: model.isEditingURL ? 1.5 : Theme.Stroke.hairline)
    )
    .overlay(alignment: .bottomLeading) {
      Rectangle()
        .fill(Color.theme.accentPrimary)
        .frame(height: Theme.Layout.browserURLProgressHeight)
        .scaleEffect(x: max(0.05, min(1, model.estimatedProgress)), y: 1, anchor: .leading)
        .opacity(model.isLoading ? 1 : 0)
        .animation(.easeOut(duration: Theme.Motion.quick), value: model.estimatedProgress)
        .animation(.easeOut(duration: Theme.Motion.quick), value: model.isLoading)
    }
    .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.browserURLRadius))
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture {
      guard !model.isEditingURL else { return }
      model.onBeginURLEditing()
    }
  }

  @ViewBuilder private var displayLabel: some View {
    if let url = model.displayURL {
      let hostText = Text(verbatim: "\u{2066}\(url.host)\u{2069}").foregroundStyle(
        Color.theme.textPrimary)
      let isolatedPath = url.path.isEmpty ? "" : "\u{2066}\(url.path)\u{2069}"
      let pathText = Text(isolatedPath).foregroundStyle(Color.theme.textMuted)
      // 先頭 LRM と LRI/PDI で段落ベース方向を LTR 固定し、数値ホスト＋RTL 文字パスでもホスト左・パス右を保つ。
      Text("\u{200E}\(hostText)\(pathText)")
        .font(Font.theme.browserURL)
        .lineLimit(1)
        .truncationMode(.tail)
        .environment(\.layoutDirection, .leftToRight)
    } else {
      Text(localization.string(.browserBarURLPlaceholder))
        .font(Font.theme.browserURL)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }
}

/// 全面表示中の `⌥` 長押し時にツールバーへ出る案内ピル。
private struct BrowserFullPeekPill: View {
  let underlay: BrowserPeekUnderlay
  let localization: LocalizationStore

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      EditorKeyCap(
        content: .glyph(EditorGlyphs.optionKey),
        foreground: Color.theme.onAccent,
        ground: Color.theme.accentPrimary)
      Text(localization.string(underlay.labelKey))
        .font(Font.theme.browserPeekPill)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
    }
    .fixedSize()
  }
}

/// ツールバーの host。ボタン押下で host 自身が first responder を奪わないようにする
/// （子孫の `NSTextField` への明示フォーカスは妨げない）。
final class BrowserBarHost: NSHostingView<BrowserBarRoot> {
  override var acceptsFirstResponder: Bool { false }
}
