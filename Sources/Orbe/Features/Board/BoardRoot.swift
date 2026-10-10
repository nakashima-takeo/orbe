import SwiftUI

/// ボードの SwiftUI ルート。器（`BoardView`）の中の別 root なので環境は明示注入する。地は端末・エディター面と同じ veil。
struct BoardRoot: View {
  let translucency: ChromeTranslucency
  let localization: LocalizationStore

  var body: some View {
    BoardEmptyView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(translucency.baseFill)
      .environment(\.localization, localization)
  }
}

/// まだ何も置かれていないボード: 中央に沈んだ一文。
struct BoardEmptyView: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(l10n.string(.boardEmpty))
      .font(Font.theme.editorLead)
      .foregroundStyle(Color.theme.textMuted)
  }
}

#if DEBUG
  #Preview("BoardRoot") {
    BoardRoot(translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja))
      .frame(width: 640, height: 480)
  }
#endif
