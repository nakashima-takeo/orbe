import OrbeEditorCore
import SwiftUI

/// エディター面の本体に文字だけを出す SwiftUI ルート——本体が空のときの画面ごとの表示（→ `EditorEmptyView`）、表示できない
/// diff の理由の一文、読み込み中の diff（何も出さない）。器の中の別 root なので環境は明示注入する。
struct EditorFaceRoot: View {
  /// 器に出すもの。
  enum Content: Equatable {
    /// 本体が空——その画面の空・使えないときの表示。
    case empty(EditorScreen)
    case blank
    case notice(L10nKey)
  }

  let localization: LocalizationStore
  var content = Content.blank
  /// 空・使えないときの表示が読む、左の列の一覧の状態（根が替われば pane が root ごと作り直す）。
  let scm: ScmPanel
  let pullRequest: PrPanel
  /// ボタンの外を押した（pane が焦点を取る）。
  var onPress: () -> Void = {}

  var body: some View {
    Group {
      switch content {
      case .empty(let screen): EditorEmptyView(screen: screen, scm: scm, pullRequest: pullRequest)
      case .blank: Color.clear
      case .notice(let key): EditorNoticeView(key: key)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture(perform: onPress)
    .environment(\.localization, localization)
  }
}

/// 本体の中央の一文（表示できない diff の理由）。
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

/// pane の本体の種類——文書（文書の面）・diff（新しい側の面、並列なら左右 2 面）・空状態。本体の矩形・焦点の行き先・当たり・
/// ファイル内検索の欄はこの種類で分かれる。
enum EditorBody {
  case document(EditorDocument)
  case diff(EditorDiff)
  case empty
}
