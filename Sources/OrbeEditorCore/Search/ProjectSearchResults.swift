import Foundation

/// 検索結果の 1 つの一致。`line` は 0 始まりの行、`column` は行の中の区間（UTF-16。行末の `\r` を外す前の行で）。
public struct SearchMatch: Equatable, Sendable {
  public var line: Int
  public var column: NSRange
  public var preview: SearchPreview

  public init(line: Int, column: NSRange, preview: SearchPreview) {
    self.line = line
    self.column = column
    self.preview = preview
  }
}

/// 1 ファイルの一致のまとまり。`path` は根からの相対パス。出どころがディスク（git）なら `document` は nil、開いている
/// 文書なら文書の区間（`matches` と同じ順）と、それを探した文書の版を持つ。
public struct SearchFileMatches: Equatable, Sendable {
  public let path: String
  public private(set) var matches: [SearchMatch]
  public private(set) var document: DocumentSpan?

  public struct DocumentSpan: Equatable, Sendable {
    public var ranges: [NSRange]
    public var version: Int

    public init(ranges: [NSRange], version: Int) {
      self.ranges = ranges
      self.version = version
    }
  }

  public init(path: String, matches: [SearchMatch], document: DocumentSpan? = nil) {
    self.path = path
    self.matches = matches
    self.document = document
  }

  public var count: Int { matches.count }

  /// 開いている文書の編集に合わせて区間をずらし、区間の版を編集の後の版 `version` にする（編集に掛かる一致は落とす——
  /// `TextEdit.track` と同じ規則）。行・行の中の位置・プレビューは取り直すまで前のまま。
  public mutating func track(_ edit: TextEdit, version: Int) {
    guard var document else { return }
    var ranges: [NSRange] = []
    var kept: [SearchMatch] = []
    for (range, match) in zip(document.ranges, matches) {
      guard let moved = edit.track([range]).first else { continue }
      ranges.append(moved)
      kept.append(match)
    }
    document.ranges = ranges
    document.version = version
    matches = kept
    self.document = document
  }

  /// ディスクのまとまりを、開いた文書の区間に直す（行頭のオフセット ＋ 行の中の位置。本文の外へ出る一致は落とす）。
  public mutating func attach(to text: TextRope, version: Int) {
    var ranges: [NSRange] = []
    var kept: [SearchMatch] = []
    for match in matches where match.line < text.lineCount {
      let start = text.lineStart(match.line)
      let range = NSRange(
        location: start + match.column.location, length: match.column.length)
      guard NSMaxRange(range) <= text.lineEnd(match.line) else { continue }
      ranges.append(range)
      kept.append(match)
    }
    matches = kept
    document = DocumentSpan(ranges: ranges, version: version)
  }

  fileprivate mutating func truncate(to count: Int) {
    matches = Array(matches.prefix(count))
    if let ranges = document?.ranges { document?.ranges = Array(ranges.prefix(count)) }
  }
}

/// 検索結果——ファイルごとのまとまりをパスの順（`FileNameOrder.comparePaths`）に並べ、一致の総数を `limit` で打ち切る。
/// 同じパスのまとまりは 1 つ（置き直せば置き換わる）。
public struct ProjectSearchResults: Equatable, Sendable {
  /// 一致の総数の上限（VS Code の検索ビューの maxResults）。
  public static let limit = 20_000

  public private(set) var files: [SearchFileMatches] = []
  public private(set) var total = 0
  /// 上限で打ち切った（ちょうど上限に達したときも——その先を探していない）。
  public private(set) var isLimited = false

  public init() {}

  public var isEmpty: Bool { files.isEmpty }

  public func index(of path: String) -> Int? {
    let index = position(of: path)
    return index < files.count && files[index].path == path ? index : nil
  }

  public subscript(path: String) -> SearchFileMatches? {
    index(of: path).map { files[$0] }
  }

  /// まとまりを置く（同じパスがあれば置き換える）。一致が 0 ならそのパスを除く。総数が上限を超えるぶんは捨てて打ち切りを
  /// 立てる。
  public mutating func set(_ file: SearchFileMatches) {
    remove(file.path)
    guard file.count > 0 else { return }
    var file = file
    let room = Self.limit - total
    if file.count > room {
      isLimited = true
      guard room > 0 else { return }
      file.truncate(to: room)
    }
    files.insert(file, at: position(of: file.path))
    total += file.count
    if total >= Self.limit { isLimited = true }
  }

  public mutating func remove(_ path: String) {
    guard let index = index(of: path) else { return }
    total -= files[index].count
    files.remove(at: index)
  }

  /// 開いている文書のまとまりを編集に合わせてずらす（`version` は編集の後の版）。
  public mutating func track(_ path: String, _ edit: TextEdit, version: Int) {
    guard let index = index(of: path) else { return }
    total -= files[index].count
    files[index].track(edit, version: version)
    total += files[index].count
    if files[index].count == 0 { files.remove(at: index) }
  }

  /// ディスクのまとまりを、開いた文書の区間に直す。
  public mutating func attach(_ path: String, to text: TextRope, version: Int) {
    guard let index = index(of: path) else { return }
    total -= files[index].count
    files[index].attach(to: text, version: version)
    total += files[index].count
    if files[index].count == 0 { files.remove(at: index) }
  }

  /// パスが並ぶ位置（二分探索）。
  private func position(of path: String) -> Int {
    var low = 0
    var high = files.count
    while low < high {
      let mid = (low + high) / 2
      if FileNameOrder.comparePaths(files[mid].path, path) == .orderedAscending {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}
