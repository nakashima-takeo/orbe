import SwiftUI

/// ブラウザツール一式（BrowserHeader / BrowserBody / BrowserFooter）。
/// dev サーバーが稼働しているプロジェクトの実ページを WKWebView で描く。dev サーバー稼働時のみ
/// その URL を出し、未稼働なら空状態を出す。chrome 色はテーマ追従（Color.theme.*）。

/// ブラウザツールのヘッダー（HeaderRow 共用）。ナビ（‹ › ⟳）＋URLバー（現在 URL の表示のみ）。
struct BrowserHeader: View {
  @Bindable var model: EditorPaneModel

  var body: some View {
    HeaderRow {
      navGlyph("‹", font: .system(size: 12), enabled: model.browserCanGoBack) {
        model.actions?.browserGoBack()
      }
      navGlyph("›", font: .system(size: 12), enabled: model.browserCanGoForward) {
        model.actions?.browserGoForward()
      }
      navGlyph("⟳", font: Font.theme.paneRow, enabled: model.devServerURL != nil) {
        model.actions?.browserReload()
      }
      urlBar
    }
  }

  /// 現在 URL の表示バー。緑ドットは dev サーバー稼働時のみ点灯。
  private var urlBar: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(model.devServerURL != nil ? Color.theme.diffAdded : dimDot)
        .frame(width: 6, height: 6)
      Text(verbatim: displayText)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(Font.theme.paneControl)
    .foregroundStyle(Color.theme.textPrimary)
    .padding(.horizontal, 9)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity)
    .background(RoundedRectangle(cornerRadius: 4).fill(Color.theme.tabRowBg))
  }

  /// 未稼働時の URLバー緑ドットの減光色。
  private var dimDot: Color { Color.theme.textMuted.opacity(0.4) }

  /// URL からスキームと末尾スラッシュを落とした表示文字列（例: `localhost:3000`）。
  private var displayText: String {
    guard let url = model.browserDisplayURL else { return "" }
    var text = url.absoluteString
    for scheme in ["http://", "https://"] where text.hasPrefix(scheme) {
      text.removeFirst(scheme.count)
    }
    if text.hasSuffix("/") { text.removeLast() }
    return text
  }

  private func navGlyph(
    _ symbol: String, font: Font, enabled: Bool, _ action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(verbatim: symbol)
        .font(font)
        .foregroundStyle(Color.theme.textMuted.opacity(enabled ? 1 : 0.35))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}

/// ブラウザ本体。dev サーバー稼働時は WKWebView（model 保持の 1 インスタンス）、未稼働は空状態。
struct BrowserBody: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n

  var body: some View {
    Group {
      if model.devServerURL != nil {
        NSViewContainer(view: model.webView)
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// dev サーバー未起動時の本文ローカルな空状態（dead な localhost は出さない）。
  private var emptyState: some View {
    VStack(spacing: 6) {
      Text(l10n.string(.browserDevServerOff))
        .font(Font.theme.paneRow)
        .foregroundStyle(Color.theme.textSecondary)
      Text(l10n.string(.browserDevServerHint))
        .font(Font.theme.paneAnnotation)
        .foregroundStyle(Color.theme.textMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Theme.Space.phrase)
  }
}

/// ブラウザ下端の dev 情報ストリップ（BrowserFooter・高さ24）。chrome 色はテーマ追従。
struct BrowserFooter: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let running = model.devServerURL != nil
    return HStack(spacing: 8) {
      Circle()
        .fill(running ? Color.theme.diffAdded : Color.theme.textMuted.opacity(0.4))
        .frame(width: 6, height: 6)
      Text(l10n.string(running ? .browserDevServerRunning : .browserDevServerStopped))
      Spacer(minLength: 0)
      Button {
        model.actions?.openBrowserExternally()
      } label: {
        Text(l10n.string(.browserOpenExternal))
          .foregroundStyle(running ? Color.theme.textSecondary : Color.theme.textMuted)
      }
      .buttonStyle(.plain)
      .disabled(!running)
    }
    .font(Font.theme.paneSegment)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.07)).frame(height: 1)
    }
  }
}

#if DEBUG
  #Preview("Browser Tool") {
    let model = EditorPaneModel()
    return VStack(spacing: 0) {
      BrowserHeader(model: model)
      BrowserBody(model: model)
      BrowserFooter(model: model)
    }
    .frame(width: 376, height: 440)
    .background(Color.theme.paneWash)
    .background(Color.theme.bgBase)
  }
#endif
