import Foundation

/// `git log --format=%H%x1f%h%x1f%an%x1f%at%x1f%P%x1f%D%x1f%s%x1e` の出力をパースする。
enum LogParser {
  /// レコード区切り（U+001E）。
  private static let recordSeparator: Character = "\u{1e}"
  /// フィールド区切り（U+001F）。
  private static let fieldSeparator: Character = "\u{1f}"

  static func parse(_ text: String) -> [Commit] {
    text.split(separator: recordSeparator).compactMap { record in
      // --format はレコード毎に改行を付けるため、区切りの前後に紛れる改行を除く。
      let fields = record.trimmingCharacters(in: .newlines)
        .split(separator: fieldSeparator, omittingEmptySubsequences: false)
      guard fields.count == 7, let epoch = TimeInterval(fields[3]) else { return nil }
      return Commit(
        oid: String(fields[0]),
        shortOid: String(fields[1]),
        author: String(fields[2]),
        date: Date(timeIntervalSince1970: epoch),
        parents: fields[4].split(separator: " ").map(String.init),
        refs: fields[5].components(separatedBy: ", ").filter { !$0.isEmpty },
        subject: String(fields[6]))
    }
  }
}
