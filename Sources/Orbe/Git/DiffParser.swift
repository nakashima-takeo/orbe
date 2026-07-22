import Foundation

/// `git diff`/`git diff-tree` を `-c core.quotepath=false` と `GitRepo.renderFlags`
/// （`--no-color --no-ext-diff --no-textconv --find-renames -U3`）で走らせた
/// unified diff 出力をパースする。フラグ契約の単一ソースは `GitRepo.renderFlags`。
enum DiffParser {

  /// unified diff 出力（複数ファイル可）を FileDiff 配列へ。
  static func parse(_ text: String) -> [FileDiff] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var diffs: [FileDiff] = []
    var i = 0
    while i < lines.count {
      if lines[i].hasPrefix("diff --git ") {
        diffs.append(parseFile(lines, &i))
      } else {
        i += 1
      }
    }
    return diffs
  }

  // MARK: - 1 ファイル分

  private static func parseFile(_ lines: [String], _ i: inout Int) -> FileDiff {
    let gitLine = lines[i]
    i += 1
    var fields = HeaderFields()
    var hunks: [Hunk] = []

    while i < lines.count {
      let line = lines[i]
      if line.hasPrefix("diff --git ") { break }
      if line.hasPrefix("@@ -"), let header = parseHunkHeader(line) {
        i += 1
        hunks.append(parseHunkBody(lines, &i, header: header))
        continue
      }
      fields.consume(line)
      i += 1
    }

    // ---/+++ も rename from/to も無いファイル（mode 変更のみ・バイナリ等）は
    // diff --git 行を同一パス前提の中点分割で復元する。
    if !fields.sawOld || !fields.sawNew {
      let path = midpointPath(gitLine)
      if !fields.sawOld { fields.oldPath = path }
      if !fields.sawNew { fields.newPath = path }
    }

    return FileDiff(
      oldPath: fields.oldPath, newPath: fields.newPath, isBinary: fields.isBinary,
      oldMode: fields.oldMode, newMode: fields.newMode, similarity: fields.similarity,
      hunks: fields.isBinary ? [] : hunks
    )
  }

  /// diff --git 直後の拡張ヘッダ・---/+++ 行から拾うフィールド群。
  /// パスは曖昧な diff --git 行より rename/copy from/to・---/+++ 行を信頼する。
  private struct HeaderFields {
    var oldPath: String?
    var newPath: String?
    /// /dev/null（= nil）と「未検出」を区別する。
    var sawOld = false
    var sawNew = false
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    var similarity: Int?

    mutating func consume(_ line: String) {
      switch line {
      case let l where l.hasPrefix("old mode "):
        oldMode = rest(l, "old mode ")
      case let l where l.hasPrefix("new mode "):
        newMode = rest(l, "new mode ")
      case let l where l.hasPrefix("deleted file mode "):
        oldMode = rest(l, "deleted file mode ")
        newPath = nil
        sawNew = true
      case let l where l.hasPrefix("new file mode "):
        newMode = rest(l, "new file mode ")
        oldPath = nil
        sawOld = true
      case let l where l.hasPrefix("similarity index "):
        similarity = Int(rest(l, "similarity index ").dropLast())  // 末尾の %
      case let l where l.hasPrefix("rename from "):
        oldPath = rest(l, "rename from ")
        sawOld = true
      case let l where l.hasPrefix("copy from "):
        oldPath = rest(l, "copy from ")
        sawOld = true
      case let l where l.hasPrefix("rename to "):
        newPath = rest(l, "rename to ")
        sawNew = true
      case let l where l.hasPrefix("copy to "):
        newPath = rest(l, "copy to ")
        sawNew = true
      case let l where l.hasPrefix("index "):
        // `index old..new mode` — mode 変更がないファイルはここにだけ mode が出る
        let parts = rest(l, "index ").split(separator: " ")
        if parts.count == 2 {
          oldMode = oldMode ?? String(parts[1])
          newMode = newMode ?? String(parts[1])
        }
      case let l where l.hasPrefix("--- "):
        oldPath = filePath(rest(l, "--- "), stripping: "a/")
        sawOld = true
      case let l where l.hasPrefix("+++ "):
        newPath = filePath(rest(l, "+++ "), stripping: "b/")
        sawNew = true
      case let l where l.hasPrefix("Binary files ") || l == "GIT binary patch":
        isBinary = true
      default:
        break
      }
    }

    private func rest(_ line: String, _ prefix: String) -> String {
      String(line.dropFirst(prefix.count))
    }

    /// ---/+++ 行のパス。`/dev/null` は nil。空白を含むパスに付く末尾タブを除去する。
    private func filePath(_ raw: String, stripping prefix: String) -> String? {
      var path = raw
      if path.hasSuffix("\t") { path = String(path.dropLast()) }
      if path == "/dev/null" { return nil }
      if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
      return path
    }
  }

  /// `diff --git a/P b/P` を「両側同一パス」前提で中点分割する。
  /// rename/copy は rename from/to 行で確定済みなので、ここに来るのは同一パスのみ。
  private static func midpointPath(_ gitLine: String) -> String? {
    let rest = gitLine.dropFirst("diff --git ".count)
    // "a/" + P + " " + "b/" + P
    let total = rest.count
    guard total >= 5, (total - 5).isMultiple(of: 2) else { return nil }
    let length = (total - 5) / 2
    let old = rest.prefix(2 + length)
    let new = rest.suffix(2 + length)
    guard old.hasPrefix("a/"), new.hasPrefix("b/"), old.dropFirst(2) == new.dropFirst(2)
    else { return nil }
    return String(old.dropFirst(2))
  }

  // MARK: - hunk

  private struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let heading: String
  }

  /// `@@ -l[,c] +l[,c] @@ heading` をパースする。count 省略時は 1。
  private static func parseHunkHeader(_ line: String) -> HunkHeader? {
    let numbersStart = line.index(line.startIndex, offsetBy: 4)  // "@@ -" の直後
    guard let close = line.range(of: " @@", range: numbersStart..<line.endIndex) else { return nil }
    let parts = line[numbersStart..<close.lowerBound].split(separator: " ")
    guard parts.count == 2, parts[1].hasPrefix("+"),
      let old = startCount(parts[0]), let new = startCount(parts[1].dropFirst())
    else { return nil }
    var heading = String(line[close.upperBound...])
    if heading.hasPrefix(" ") { heading = String(heading.dropFirst()) }
    return HunkHeader(
      oldStart: old.start, oldCount: old.count,
      newStart: new.start, newCount: new.count, heading: heading
    )
  }

  private static func startCount(_ s: Substring) -> (start: Int, count: Int)? {
    let nums = s.split(separator: ",")
    guard let first = nums.first, let start = Int(first) else { return nil }
    let count = nums.count > 1 ? Int(nums[1]) ?? 1 : 1
    return (start, count)
  }

  /// hunk 本文。残数で終端を判定し、行番号をヘッダから累積する。
  private static func parseHunkBody(_ lines: [String], _ i: inout Int, header: HunkHeader) -> Hunk {
    var body: [DiffLine] = []
    var oldRemain = header.oldCount
    var newRemain = header.newCount
    var oldLine = header.oldStart
    var newLine = header.newStart

    while i < lines.count, oldRemain > 0 || newRemain > 0 {
      let line = lines[i]
      if line.hasPrefix("\\") {
        foldNoNewline(into: &body)
        i += 1
        continue
      }
      switch line.first {
      case "+":
        body.append(DiffLine(kind: .added, text: String(line.dropFirst()), newLine: newLine))
        newLine += 1
        newRemain -= 1
      case "-":
        body.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: oldLine))
        oldLine += 1
        oldRemain -= 1
      case " ", nil:
        body.append(
          DiffLine(
            kind: .context, text: String(line.dropFirst()), oldLine: oldLine, newLine: newLine))
        oldLine += 1
        newLine += 1
        oldRemain -= 1
        newRemain -= 1
      default:
        // 想定外の行 = hunk の途中終端。壊れた入力でも残りを外側へ返す。
        oldRemain = 0
        newRemain = 0
        continue
      }
      i += 1
    }
    // 最終行直後の `\ No newline at end of file`
    if i < lines.count, lines[i].hasPrefix("\\") {
      foldNoNewline(into: &body)
      i += 1
    }
    return Hunk(
      oldStart: header.oldStart, oldCount: header.oldCount,
      newStart: header.newStart, newCount: header.newCount,
      sectionHeading: header.heading, lines: body
    )
  }

  /// `\ No newline at end of file` を直前の行の noNewlineAtEnd=true に畳む。
  private static func foldNoNewline(into body: inout [DiffLine]) {
    guard let last = body.last else { return }
    body[body.count - 1] = DiffLine(
      kind: last.kind, text: last.text, noNewlineAtEnd: true,
      oldLine: last.oldLine, newLine: last.newLine
    )
  }
}
