import SwiftUI

// Dispatch のフッターの部品。一覧モードと最新化モードが共有する。

/// フッターの busy 表示（作成中・最新化中）。左端の `↵` を出さず、gh「読み込み中…」行と同語彙の
/// working スピナ＋muted ラベルのみ。
struct DispatchBusyLabel: View {
  let text: String

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      StatusGlyphView(kind: .working, size: 10)
      Text(text).foregroundStyle(Color.theme.textMuted)
    }
    .font(Font.theme.meta)
  }
}

/// フッターの実行説明。`↵ <target> <前置> <agent> を新しいタブで起動` の骨を 1 つの Text に連結して
/// 単位で truncate する（狭幅で個々に折り返して崩れるのを防ぐ）。
struct DispatchLaunchLine: View {
  let target: String
  let preposition: L10nKey
  let agent: String
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    (Text("↵ ").foregroundStyle(Color.theme.textMuted)
      + fontResolver.text(target, base: Theme.Typography.meta)
      .foregroundStyle(Color.theme.textPrimary)
      + Text(" " + l10n.string(preposition) + " ").foregroundStyle(Color.theme.textMuted)
      + Text(agent).foregroundStyle(Color.theme.accentPrimary)
      + Text(" " + l10n.string(.dispatchLaunchSuffix)).foregroundStyle(Color.theme.textMuted))
      .font(Font.theme.meta)
      .lineLimit(1)
      .truncationMode(.tail)
  }
}

/// フッターのブラウザで開く説明（`↵ <target> をブラウザで開く`）。色の描き分けは `DispatchLaunchLine` と同じ。
struct DispatchBrowseLine: View {
  let target: String
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    (Text("↵ ").foregroundStyle(Color.theme.textMuted)
      + fontResolver.text(target, base: Theme.Typography.meta)
      .foregroundStyle(Color.theme.textPrimary)
      + Text(" " + l10n.string(.dispatchBrowseSuffix)).foregroundStyle(Color.theme.textMuted))
      .font(Font.theme.meta)
      .lineLimit(1)
      .truncationMode(.tail)
  }
}

/// フッター右端のキーヒント 1 つ（キーは textPrimary・ラベルは親の色）。
struct DispatchKeyHint: View {
  let key: String
  let label: String

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      Text(key).foregroundStyle(Color.theme.textPrimary)
      Text(label)
    }
  }
}
