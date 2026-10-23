import Foundation

/// 版の本文の語彙——関心の単位と版の状態。
extension RootFiles {
  /// 関心の単位——根からの相対パスと版。
  struct Version: Hashable {
    let path: String
    let revision: GitRevision
  }

  /// 版の本文の状態（OID ごとに決まる）。
  enum VersionState: Equatable {
    /// 本文（作業ツリーに出したときの姿）。
    case text(String)
    /// その版に無い（index に無い・競合中・初回コミット前の HEAD を含む。ファイルでないものも）。
    case absent
    /// UTF-8 として読めない。
    case notText
    /// git から取れない（取り直しの上限に達した・まだ状態の無い版で、OID の一覧か本文を取れなかった）。
    case failed

    var text: String? {
      if case .text(let text) = self { return text }
      return nil
    }
  }
}
