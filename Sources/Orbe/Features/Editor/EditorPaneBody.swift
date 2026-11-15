import OrbeEditorCore
import SwiftUI

/// エディター面の本体に文字だけを出す SwiftUI ルート——タブの無い空状態、表示できない diff の理由の一文、読み込み中の diff
/// （何も出さない）。器の中の別 root なので環境は明示注入する。
struct EditorFaceRoot: View {
  /// 器に出すもの。
  enum Content: Equatable {
    case empty
    case blank
    case notice(L10nKey)
  }

  let localization: LocalizationStore
  var content = Content.empty

  var body: some View {
    Group {
      switch content {
      case .empty: EditorEmptyView()
      case .blank: Color.clear
      case .notice(let key): EditorNoticeView(key: key)
      }
    }
    .environment(\.localization, localization)
  }
}

/// 本体の中央の一文（表示できない diff の理由）。空状態の一文と同じ字と色。
struct EditorNoticeView: View {
  let key: L10nKey
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(l10n.string(key))
      .font(Font.theme.editorLead)
      .foregroundStyle(Color.theme.textMuted)
      .multilineTextAlignment(.center)
      .padding(Theme.Space.bar)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// pane の本体の種類——文書（文書の面）・diff（新しい側の面、並列なら左右 2 面）・空状態。本体の矩形・右列・焦点の行き先・
/// 当たり・検索バー・⌘S・列の頭の高さはこの種類で分かれる。
enum EditorBody {
  case document(EditorDocument)
  case diff(EditorDiff)
  case empty

  /// パンくずの段を持つか（空状態だけ持たない）。
  var hasBreadcrumb: Bool {
    if case .empty = self { return false }
    return true
  }
}
