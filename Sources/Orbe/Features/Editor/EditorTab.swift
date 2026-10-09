import Foundation
import OrbeEditorCore

/// エディター面のタブ 1 枚——文書のタブ（ファイルタブ）か diff のタブ。
@MainActor
enum EditorTab {
  case document(EditorDocument)
  case diff(EditorDiff)

  /// タブの識別——文書は実体の URL、diff は（根・相対パス・種類）。
  enum Key: Hashable {
    case document(URL)
    case diff(EditorDiff.Key)
  }

  var id: Key {
    switch self {
    case .document(let document): .document(document.url)
    case .diff(let diff): .diff(diff.id)
    }
  }

  /// タブが使う文書（文書のタブはその文書、作業ツリー diff は新しい側の文書）。
  var document: EditorDocument? {
    switch self {
    case .document(let document): document
    case .diff(let diff): diff.document
    }
  }

  /// タブが指すファイルの実体の URL（現在地・パンくず・ツリーの選択表示）。
  var url: URL {
    switch self {
    case .document(let document): document.url
    case .diff(let diff): diff.id.url
    }
  }
}
