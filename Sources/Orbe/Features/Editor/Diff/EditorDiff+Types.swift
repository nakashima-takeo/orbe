import Foundation
import OrbeEditorCore

extension EditorDiff {
  /// 識別——根・根からの相対パス・種類。
  struct Key: Hashable {
    let root: String
    let path: String
    let kind: Kind

    /// 作業ツリーのファイルの実体のパス。
    var url: URL { URL(fileURLWithPath: root).appendingPathComponent(path) }
  }

  enum Kind: Hashable {
    case workingTree
    case staged
  }

  /// 見せ方（アプリ全体で 1 つ。→ `AppState.diffMode`）。
  enum Mode: String, Codable {
    case inline
    case side
  }

  /// 表示できない理由。
  enum Unavailable: Equatable {
    /// UTF-8 として読めない（バイナリ・別の符号化）。
    case notText
    /// 作業ツリーのパスがシンボリックリンク。
    case symlink
    /// 競合中。
    case conflicted
    /// git から取れない。
    case failed
  }

  /// 見せられる中身。
  enum Content: Equatable {
    /// 版の本文がまだ届いていない。
    case loading
    case unavailable(Unavailable)
    case ready
  }

  /// 作業ツリー diff の新しい側。
  enum WorkingSide {
    /// 開いた文書（ファイルタブと共有する）。
    case document(EditorDocument)
    /// 作業ツリーに無い（消した）。
    case missing
    case unavailable(Unavailable)
  }
}
