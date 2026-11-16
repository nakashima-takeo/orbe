import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 1 つのパスの作業ツリー diff とステージ済み diff を開いたまま、作業ツリー・index・見せ方・打鍵を、種を決めた乱数の順で
/// 次々に変える。どの順で側が替わっても、落ち着いた時点の面の並びが、その時点の両側（git と作業ツリーから読み直した本文）
/// の行差分（ファイルとサブモジュールの置き換えなら丸ごとの置き換え）と一致し、未保存の本文が失われない。
///
/// 壊れると何が起きるか: 前の両側の並びを今の側に置いて precondition でアプリが落ちる。並びが今の両側と食い違ったまま
/// 残る。未保存の本文が消える。失敗した種と手順はメッセージに出る（同じ種で回せば同じ手順になる）。
extension EditorDiffTests {
  func testRandomTransitionsKeepTheRowsMatchingBothSides() throws {
    // 種ごとに別のリポジトリで回し、前の種のタブはテストの終わりまで持つ（窓がタブより長く生きるので、タブを先に
    // 手放すと、窓に残った diff がテストにしか無い順で解放済みのセッションを引く）。
    var tabs: [TerminalTab] = []
    for seed: UInt64 in [1, 2, 3] {
      if !tabs.isEmpty { try setUpWithError() }
      let tab = tab(modes: EditorDiffModeState())
      tabs.append(tab.0)
      guard try runTransitions(seed: seed, steps: 30, in: tab.0) else { return }
    }
  }

  /// 種 `seed` で `steps` 手を当てる。食い違えば記録して false を返す。
  private func runTransitions(seed: UInt64, steps: Int, in tab: TerminalTab) throws -> Bool {
    let modes = tab.group.view.editor.diffModes
    let session = tab.group.editor
    let pane = tab.group.view.editor
    try repo.write("other.txt", "other\n")
    let other = try session.open(repo.url("other.txt"), as: .pinned)
    let working = try session.openDiff(id("a.txt", .workingTree), as: .pinned)
    let staged = try session.openDiff(id("a.txt", .staged), as: .pinned)
    var random = SplitMix(seed: seed)
    var log: [String] = []
    let unsaved = Unsaved()

    for step in 0..<steps {
      let shown = pane.diff
      // 作業ツリーと index の手を、見せ方の手より多く引く（側の替わり方の順が、落ちた経路を作る）。
      var ops: [(String, () throws -> Void)] = [
        ("write", { try self.writeFile(self.randomText(&random)) }),
        ("write", { try self.writeFile(self.randomText(&random)) }),
        ("delete", { try self.removeEntry() }),
        ("delete", { try self.removeEntry() }),
        ("add", { self.repo.git(["add", "-A", "--", "a.txt"]) }),
        ("add", { self.repo.git(["add", "-A", "--", "a.txt"]) }),
        ("unstage", { self.repo.git(["restore", "--staged", "--", "a.txt"]) }),
        ("repository", { try self.placeRepository() }),
        ("repository", { try self.placeRepository() }),
        ("conflict", { try self.conflict() }),
        (
          shown === working ? "hide" : "show working",
          {
            session.activate(shown === working ? .document(other.url) : .diff(working.id))
          }
        ),
        ("show staged", { session.activate(.diff(staged.id)) }),
        ("mode", { modes.select(modes.mode == .inline ? .side : .inline) }),
      ]
      if shown === working, let edit = editing(working, unsaved: unsaved) { ops.append(edit) }
      let (name, op) = ops[random.next(below: ops.count)]
      log.append("\(step):\(name)")
      // 落ちたときにも種と手順が残るように、当てる前に標準エラーへ出す。
      FileHandle.standardError.write(Data("遷移 種 \(seed) \(log.joined(separator: " "))\n".utf8))
      try op()

      let truth: Truth
      do {
        truth = try readTruth()
      } catch {
        XCTFail("種 \(seed) の手順 \(log.joined(separator: " ")) の後、期待を読む git が失敗: \(error)")
        return false
      }
      if let mismatch = settle(
        pane, truth: truth, working: working, unsaved: unsaved.text)
      {
        XCTFail("種 \(seed) の手順 \(log.joined(separator: " ")) の後: \(mismatch)")
        return false
      }
    }
    return true
  }

  /// 作業ツリー diff の文書を打つ手（未保存でなければ打ち、未保存なら undo で戻す）。文書の面を見せていなければ nil。
  private func editing(_ working: EditorDiff, unsaved: Unsaved) -> (String, () throws -> Void)? {
    guard let document = working.document,
      let surface = working.newSurface as? MetalTextSurface, surface === document.surface
    else { return nil }
    if unsaved.text == nil {
      return (
        "type",
        { [self] in
          surface.selectedRange = NSRange(location: 0, length: 0)
          surface.responder.perform(#selector(NSResponder.insertText(_:)), with: "Z\n")
          unsaved.text = string(document.text)
        }
      )
    }
    return (
      "undo",
      {
        try XCTUnwrap(surface.responder.undoManager).undo()
        pumpMain(until: { !document.isDirty }, "undo で未保存でなくなる")
        unsaved.text = nil
      }
    )
  }

  /// 見せている diff が、手の後の git と作業ツリーの姿 `truth` に落ち着くまで main を回す。10 秒で落ち着かなければ、その
  /// 食い違い。
  private func settle(
    _ pane: EditorPaneView, truth: Truth, working: EditorDiff, unsaved: String?
  ) -> String? {
    var mismatch: String?
    let deadline = Date().addingTimeInterval(10)
    repeat {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
      mismatch = self.mismatch(
        pane.diff, truth: truth, working: working, mode: pane.diffModes.mode,
        unsaved: unsaved)
    } while mismatch != nil && Date() < deadline
    return mismatch
  }

  // MARK: - 手

  private func randomText(_ random: inout SplitMix) -> String {
    let words = ["one", "two", "three", "four", "x"]
    return (0..<random.next(below: 5)).map { _ in words[random.next(below: words.count)] + "\n" }
      .joined()
  }

  private var entry: URL { URL(fileURLWithPath: repo.root).appendingPathComponent("a.txt") }

  private func removeEntry() throws {
    if FileManager.default.fileExists(atPath: entry.path) {
      try FileManager.default.removeItem(at: entry)
    }
  }

  private func writeFile(_ text: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      try FileManager.default.removeItem(at: entry)
    }
    try repo.write("a.txt", text)
  }

  /// a.txt を、中にコミットを 1 つ持つリポジトリのディレクトリに置き換える。
  private func placeRepository() throws {
    let prepared = TestScratch.caseDir.appendingPathComponent("nested-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    for args in [
      ["init", "-q", "-b", "main", prepared.path],
      [
        "-C", prepared.path, "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q",
        "--allow-empty", "-m", UUID().uuidString,
      ],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess, "\(args)")
    }
    try removeEntry()
    try FileManager.default.moveItem(at: prepared, to: entry)
  }

  /// index の a.txt を競合（共通の祖先・こちら・あちらの 3 つの版）にする。
  private func conflict() throws {
    let blobs = try ["base\n", "ours\n", "theirs\n"].map { text in
      let output = GitRunner.shared.runSync(
        ["hash-object", "-w", "--stdin"], cwd: repo.dir.path, stdin: Data(text.utf8))
      XCTAssertTrue(output.isSuccess)
      return try XCTUnwrap(output.stdoutText.split(separator: "\n").first.map(String.init))
    }
    let info =
      "0 \(String(repeating: "0", count: 40))\ta.txt\n"
      + blobs.enumerated().map { "100644 \($1) \($0 + 1)\ta.txt\n" }.joined()
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["update-index", "--index-info"], cwd: repo.dir.path, stdin: Data(info.utf8)
      ).isSuccess)
  }

  // MARK: - 確かめ

  /// 見せている diff が今の両側に落ち着いていなければ、その食い違い（落ち着いていれば nil）。未保存の本文が残っているかも
  /// 見る。
  private func mismatch(
    _ shown: EditorDiff?, truth: Truth, working: EditorDiff,
    mode: EditorDiff.Mode, unsaved: String?
  ) -> String? {
    if let unsaved, string(working.document?.text) != unsaved {
      return "未保存の本文が失われた: \(String(describing: string(working.document?.text)))"
    }
    guard let shown else { return nil }
    switch expectation(shown === working ? .workingTree : .staged, truth, working) {
    case .unavailable(let reason):
      return shown.content == .unavailable(reason) ? nil : "中身 \(shown.content)・期待 \(reason)"
    case .sides(let old, let new):
      guard shown.content == .ready, !shown.pending else { return "中身 \(shown.content)" }
      let actualOld = shown.oldSource ?? nil
      let actualNew = shown.document.map { string($0.text) } ?? newRevisionText(shown)
      guard actualOld == old, actualNew == new else {
        return "両側 \(debug(actualOld)) → \(debug(actualNew))・期待 \(debug(old)) → \(debug(new))"
      }
      let hunks = expectedHunks(old: old, new: new)
      guard let rows = shown.currentRows, rows.hunks == hunks else {
        return "並び \(String(describing: shown.currentRows?.hunks))・期待 \(hunks)"
      }
      guard mode == .inline, let surface = shown.newSurface as? MetalTextSurface else { return nil }
      let removed = hunks.flatMap { Array($0.oldLines) }
      let added = hunks.flatMap { Array($0.newLines) }
      let lines = DiffRows.Side(new.map(TextRope.init)).lines
      let actualAdded = (0..<lines).filter { surface.rows.style(ofLine: $0) == DiffStyle.added }
      guard removedLines(surface.rows) == removed, actualAdded == added else {
        return "面の並び 削除 \(removedLines(surface.rows))・追加 \(actualAdded)・期待 \(removed)・\(added)"
      }
      return nil
    }
  }

  private enum Expected {
    case unavailable(EditorDiff.Unavailable)
    case sides(old: String?, new: String?)
  }

  /// 手の後の git と作業ツリーの姿——index が競合か、index の版の本文、作業ツリーの姿の本文（どちらも無ければ nil。
  /// サブモジュールは「Subproject commit」の行）。
  private struct Truth {
    let conflicted: Bool
    let index: String?
    let tree: String?
  }

  /// 期待を作るための git の読みの失敗（git を起動できない・答えが読めない）。並びの食い違いとは分けて出す。
  private struct GitReadFailure: Error, CustomStringConvertible {
    let args: [String]
    let output: GitRunner.Output
    var description: String {
      "git \(args.joined(separator: " ")) が終了コード \(output.status)・\(output.stderrText)"
    }
  }

  private func read(_ args: [String]) throws -> String {
    let output = repo.git(args)
    guard output.isSuccess else { throw GitReadFailure(args: args, output: output) }
    return output.stdoutText
  }

  /// 手の後の git と作業ツリーの姿を読む（手ごとに 1 回）。
  private func readTruth() throws -> Truth {
    let staged = try read(["ls-files", "-s", "--", "a.txt"]).split(separator: "\n")
    let entries = staged.map { $0.split(separator: " ", maxSplits: 2).map(String.init) }
    var index: String?
    if let entry = entries.first, entry.count == 3 {
      index =
        entry[0] == "160000"
        ? EditorDiff.subproject(entry[1]) : try read(["cat-file", "blob", entry[1]])
    }
    var tree: String?
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) {
      tree =
        isDirectory.boolValue
        ? EditorDiff.subproject(
          try read(["-C", entry.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .newlines))
        : try String(contentsOf: entry, encoding: .utf8)
    }
    return Truth(
      conflicted: entries.contains { $0.count == 3 && !$0[2].hasPrefix("0") }, index: index,
      tree: tree)
  }

  /// 姿 `truth` で、種類 `kind` の diff が出すべきもの。作業ツリー diff の新しい側は、未保存の文書があればその本文。
  private func expectation(_ kind: EditorDiff.Kind, _ truth: Truth, _ working: EditorDiff)
    -> Expected
  {
    if truth.conflicted { return .unavailable(.conflicted) }
    if case .staged = kind { return .sides(old: "one\ntwo\nthree\nfour\n", new: truth.index) }
    var tree = truth.tree
    if let document = working.document, document.isDirty { tree = string(document.text) }
    if truth.index == nil, tree == nil { return .unavailable(.nowhere) }
    return .sides(old: truth.index, new: tree)
  }

  /// 両側の並び——片側だけがサブモジュールの行なら丸ごとの置き換え、ほかは行差分。
  private func expectedHunks(old: String?, new: String?) -> [LineHunk] {
    let (oldRope, newRope) = (old.map(TextRope.init), new.map(TextRope.init))
    let isSubproject = { (text: String?) in text?.hasPrefix("Subproject commit ") == true }
    if let old, let new, isSubproject(old) != isSubproject(new) {
      return [
        LineHunk(old: 0..<DiffRows.Side(oldRope).lines, new: 0..<DiffRows.Side(newRope).lines)
      ]
    }
    return DiffRows.hunks(old: oldRope, new: newRope, limit: EditorDiff.hunkLimit)
  }

  private func newRevisionText(_ diff: EditorDiff) -> String? {
    diff.newRevisionSide.isAbsent ? nil : diff.newRevision.map { string($0.text) }
  }

  private func string(_ text: TextRope) -> String {
    String(decoding: text.contiguousUnits(), as: UTF16.self)
  }

  private func string(_ text: TextRope?) -> String? { text.map(string) }

  private func debug(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "無し" }
}

/// 打って未保存にした文書の本文（未保存でなければ nil）。手の中から書き換える。
private final class Unsaved {
  var text: String?
}

/// 種を決めた乱数（SplitMix64）。同じ種なら同じ列を返す。
private struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next(below bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(bound))
  }
}
