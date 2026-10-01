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

  /// 本文 `text` の区間 `range` の字が、探した字（プレビューの一致。長い一致は頭だけを持つ）と同じか。
  func agrees(with text: TextRope, at range: NSRange) -> Bool {
    let searched = preview.match.utf16
    guard searched.count <= range.length, NSMaxRange(range) <= text.length else { return false }
    return text.substring(NSRange(location: range.location, length: searched.count)).utf16
      .elementsEqual(searched)
  }
}

/// 1 ファイルの一致のまとまり。`path` は根からの相対パス。出どころがディスク（git）なら `document` は nil、開いている
/// 文書なら文書の区間（`matches` と同じ順）と、それを探した文書の版を持つ。パスの順序の鍵は作ったときに割っておく（まとまりは
/// 裏で作るので、main で並べるときに割らない）。
public struct SearchFileMatches: Equatable, Sendable {
  public let path: String
  public let pathKey: FileNameOrder.PathKey
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
    pathKey = FileNameOrder.PathKey(path)
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

  /// ディスクのまとまりを、開いた文書の区間に直す（行頭のオフセット ＋ 行の中の位置）。本文の外へ出る一致と、区間の字が
  /// 探した字と違う一致（探した後にファイルが変わった）は落とす。落とした一致があれば true。
  public mutating func attach(to text: TextRope, version: Int) -> Bool {
    var ranges: [NSRange] = []
    var kept: [SearchMatch] = []
    for match in matches where match.line < text.lineCount {
      let start = text.lineStart(match.line)
      let range = NSRange(
        location: start + match.column.location, length: match.column.length)
      guard NSMaxRange(range) <= text.lineEnd(match.line), match.agrees(with: text, at: range)
      else { continue }
      ranges.append(range)
      kept.append(match)
    }
    let dropped = kept.count < matches.count
    matches = kept
    document = DocumentSpan(ranges: ranges, version: version)
    return dropped
  }

  /// 開いている文書の区間のうち、字が探した字と違う一致を落とす（区間の版が同じでも本文が違いうる——閉じて開き直した文書は
  /// 版を 0 から数え直す）。落とした一致があれば true。
  public mutating func dropDisagreeing(with text: TextRope) -> Bool {
    guard var document else { return false }
    var ranges: [NSRange] = []
    var kept: [SearchMatch] = []
    for (range, match) in zip(document.ranges, matches) where match.agrees(with: text, at: range) {
      ranges.append(range)
      kept.append(match)
    }
    guard kept.count < matches.count else { return false }
    document.ranges = ranges
    matches = kept
    self.document = document
    return true
  }

  fileprivate mutating func truncate(to count: Int) {
    matches = Array(matches.prefix(count))
    if let ranges = document?.ranges { document?.ranges = Array(ranges.prefix(count)) }
  }
}

/// 検索結果——ファイルごとのまとまりをパスの順（`FileNameOrder.comparePaths`）に並べ、一致の総数を `limit` で打ち切る。
/// 同じパスのまとまりは 1 つ（置き直せば置き換わる）。まとまりの列を置くときはパスの順に並べて渡す（並べるのは裏の仕事）。
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
    let index = Self.position(of: FileNameOrder.PathKey(path), in: files, from: 0)
    return index < files.count && files[index].path == path ? index : nil
  }

  public subscript(path: String) -> SearchFileMatches? {
    index(of: path).map { files[$0] }
  }

  /// まとまりを置く（同じパスがあれば置き換える）。一致が 0 ならそのパスを除く。総数が上限を超えるぶんは捨てて打ち切りを
  /// 立てる。
  public mutating func set(_ file: SearchFileMatches) {
    var file = file
    let index = Self.position(of: file.pathKey, in: files, from: 0)
    let replaces = index < files.count && files[index].path == file.path
    if replaces { total -= files[index].count }
    if admit(&file) {
      if replaces { files[index] = file } else { files.insert(file, at: index) }
    } else if replaces {
      files.remove(at: index)
    }
  }

  /// パスの順に並んだまとまりの列を置く（1 つずつ `set` するのと同じ結果）。比べるのは置く数 × log(今の数) 回だけで、
  /// 列は 1 度だけ組み直す。
  public mutating func set(sorted batch: [SearchFileMatches]) {
    guard !batch.isEmpty else { return }
    var merged: [SearchFileMatches] = []
    merged.reserveCapacity(files.count + batch.count)
    var next = 0
    for var file in batch {
      let position = Self.position(of: file.pathKey, in: files, from: next)
      merged.append(contentsOf: files[next..<position])
      next = position
      if next < files.count, files[next].path == file.path {
        total -= files[next].count
        next += 1
      }
      guard admit(&file) else { continue }
      merged.append(file)
    }
    merged.append(contentsOf: files[next...])
    files = merged
  }

  /// 上限の中へ入れる（入らないぶんを捨て、打ち切りを立てる）。置くものが残らなければ false。
  private mutating func admit(_ file: inout SearchFileMatches) -> Bool {
    guard file.count > 0 else { return false }
    let room = Self.limit - total
    if file.count > room {
      isLimited = true
      guard room > 0 else { return false }
      file.truncate(to: room)
    }
    total += file.count
    if total >= Self.limit { isLimited = true }
    return true
  }

  /// 開いている文書のまとまりを編集に合わせてずらす（`version` は編集の後の版）。
  public mutating func track(_ path: String, _ edit: TextEdit, version: Int) {
    guard let index = index(of: path) else { return }
    total -= files[index].count
    files[index].track(edit, version: version)
    total += files[index].count
    if files[index].count == 0 { files.remove(at: index) }
  }

  /// ディスクのまとまりを、開いた文書の区間に直す（→ `SearchFileMatches.attach`）。落とした一致があれば true。
  @discardableResult
  public mutating func attach(_ path: String, to text: TextRope, version: Int) -> Bool {
    update(path) { $0.attach(to: text, version: version) }
  }

  /// 開いている文書のまとまりから、字が本文と違う一致を落とす（→ `SearchFileMatches.dropDisagreeing`）。落とした一致が
  /// あれば true。
  public mutating func dropDisagreeing(_ path: String, with text: TextRope) -> Bool {
    update(path) { $0.dropDisagreeing(with: text) }
  }

  /// まとまり 1 つを変え、総数を合わせる（一致が無くなれば消す）。
  private mutating func update(_ path: String, _ change: (inout SearchFileMatches) -> Bool) -> Bool
  {
    guard let index = index(of: path) else { return false }
    total -= files[index].count
    let changed = change(&files[index])
    total += files[index].count
    if files[index].count == 0 { files.remove(at: index) }
    return changed
  }

  /// パスの順に並んだ `files` の `from` 以降で、`key` のパスが並ぶ位置（二分探索）。
  public static func position(
    of key: FileNameOrder.PathKey, in files: [SearchFileMatches], from start: Int
  ) -> Int {
    var low = start
    var high = files.count
    while low < high {
      let mid = (low + high) / 2
      if FileNameOrder.comparePaths(files[mid].pathKey, key) == .orderedAscending {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}
