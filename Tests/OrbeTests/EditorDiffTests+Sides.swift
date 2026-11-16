import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の側の決まり方——新しい側の文書が替わったとき（並びが載るまで出さない・仮のタブとタブ行・未保存が下りたとき）、
/// 両側とも無いパス、途中のシンボリックリンク、サブモジュール。壊れると、diff タブに並びの無い面が一瞬出る・未保存の文書を
/// 使う仮のタブが黙って入れ替わる・消えたファイルの diff が古いまま残る・リンク先の別のファイルが出る・空の diff が理由
/// なしに出る・サブモジュールの行が「git から取れない」になる。
extension EditorDiffTests {
  /// diff だけが持つファイルが消えて戻った直後は、新しい文書の行差分が届くまで本体に何も出さず、届けば出す。
  func testADiffOnlyDocumentThatComesBackShowsNothingUntilItsRowsArrive() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let contents = try Data(contentsOf: repo.url("a.txt"))
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    pumpMain(until: { diff.document == nil && diff.content == .ready }, "消えたファイルの diff")

    try contents.write(to: repo.url("a.txt"))
    try XCTUnwrap(diff.rootObserver).rootFiles(diff.files, filesDidChange: .scanAll)
    XCTAssertNotNil(diff.document, "前提: 戻ったファイルの文書に替わる")
    XCTAssertEqual(diff.content, .loading, "並びが載るまで何も出さない")
    XCTAssertNil(diff.newSurface)
    waitRows(diff, "行差分が届く") { self.removedLines($0) == [1] }
  }

  /// 未保存のファイルが外で消えて戻ると、それを新しい側に使うようになった仮の diff タブは普通のタブになり、未保存の印が
  /// 出る。
  func testAPreviewDiffIsPinnedWhenItSwitchesToAnUnsavedDocument() throws {
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    let contents = try Data(contentsOf: repo.url("a.txt"))
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let key = id("a.txt", .workingTree)
    let diff = try tab.group.editor.openDiff(key, as: .preview)
    XCTAssertNil(diff.document, "前提: 消えたファイルの diff")
    XCTAssertEqual(tab.group.editor.previewID, .diff(key), "前提: 仮のタブ")

    try contents.write(to: repo.url("a.txt"))
    pumpMain(until: { diff.document === document }, "戻ったファイルの未保存の文書を使う")
    XCTAssertNil(tab.group.editor.previewID, "仮のタブは普通になる")
    XCTAssertEqual(tab.group.view.editor.shell.tabs.map(\.isDirty), [true, true], "diff タブにも未保存の印")
  }

  /// 未保存の文書を使う diff を仮で開くと、今の仮のタブは残り、diff は末尾の普通のタブになる。
  func testAnUnsavedDocumentsDiffOpensAsAPinnedTabAtTheEnd() throws {
    try repo.write("b.txt", "b\n")
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    try tab.group.editor.open(repo.url("b.txt"), as: .preview)
    let preview = try XCTUnwrap(tab.group.editor.previewID)
    let key = id("a.txt", .workingTree)
    try tab.group.editor.openDiff(key, as: .preview)
    XCTAssertEqual(tab.group.editor.previewID, preview, "今の仮のタブは残る")
    XCTAssertEqual(tab.group.editor.tabs.map(\.id).last, .diff(key), "末尾の普通のタブ")
  }

  /// 未追跡のファイルの作業ツリー diff を見せている間に、未保存のままファイルが消え、保存時の本文へ戻して未保存が下りると、
  /// その時点で diff が今の作業ツリーの姿（両側とも無い）に追いつく。
  func testAnUntrackedFilesDiffCatchesUpWhenTheUnsavedMarkClearsLater() throws {
    try repo.write("u.txt", "u\n")
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("u.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    let diff = try tab.group.editor.openDiff(id("u.txt", .workingTree), as: .pinned)
    waitRows(diff, "追加が出る") { $0.style(ofLine: 0) == DiffStyle.added }
    try FileManager.default.removeItem(at: repo.url("u.txt"))
    pumpMain(until: { diff.workingTree?.workingStale == true }, "前提: 消えたと知り、読み直しを保留した")
    XCTAssertTrue(diff.document === document, "前提: 未保存の間は手放さない")

    document.surface.replaceAll(with: "u\n")
    XCTAssertTrue(document.isDirty, "前提: 同じ長さなので、未保存は裏の比べで後から下りる")
    pumpMain(until: { !document.isDirty }, "前提: 未保存が下りる")
    XCTAssertEqual(diff.content, .unavailable(.nowhere), "未保存が下りた時点で追いつく")
  }

  /// index にも作業ツリーにも無いパス・HEAD にも index にも無いパスの diff は、種類ごとの理由の一文を出す。開いた後で両側とも
  /// 無くなったときも同じ。
  func testADiffOfAPathInNeitherSideSaysWhy() throws {
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let working = try tab.group.editor.openDiff(id("nope.txt", .workingTree), as: .pinned)
    pumpMain(until: { working.content == .unavailable(.nowhere) }, "作業ツリー")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNowhereInWorkingTree) })
    let staged = try tab.group.editor.openDiff(id("nope.txt", .staged), as: .pinned)
    pumpMain(until: { staged.content == .unavailable(.nowhere) }, "ステージ済み")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNowhereStaged) })

    try repo.write("u.txt", "u\n")
    let untracked = try tab.group.editor.openDiff(id("u.txt", .workingTree), as: .pinned)
    waitRows(untracked, "追加が出る") { $0.style(ofLine: 0) == DiffStyle.added }
    try FileManager.default.removeItem(at: repo.url("u.txt"))
    pumpMain(until: { untracked.content == .unavailable(.nowhere) }, "開いた後で両側とも無くなった")
  }

  /// 追跡中のディレクトリがシンボリックリンクに置き換わると、作業ツリー diff の新しい側は「消した」（全部の行が削除）で、
  /// リンク先のファイルを開かない。
  func testATrackedDirectoryReplacedByASymlinkShowsTheFileAsRemoved() throws {
    try repo.write("dir/f.txt", "f\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "dir"]).isSuccess)
    let outside = TestScratch.caseDir.appendingPathComponent("outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("other\n".utf8).write(to: outside.appendingPathComponent("f.txt"))
    try FileManager.default.removeItem(at: repo.url("dir"))
    try FileManager.default.createSymbolicLink(at: repo.url("dir"), withDestinationURL: outside)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("dir/f.txt", .workingTree), as: .pinned)
    waitRows(diff, "全部の行が削除") { self.removedLines($0) == [0, 1] }
    XCTAssertNil(diff.document, "リンク先の文書を開かない")
  }

  /// サブモジュールの行は「Subproject commit」の 1 行の差——作業ツリーは index のコミット ↔ 取り出しているコミット（中が
  /// 変わっていれば -dirty）、ステージ済みは HEAD ↔ index。
  func testASubmoduleRowShowsTheSubprojectCommitLines() throws {
    try repo.addSubmodule("sub")
    let commit = {
      self.repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText.trimmingCharacters(in: .newlines)
    }
    let first = commit()
    try repo.write("sub/t.txt", "changed\n")
    let (tab, _) = tab()
    let dirty = try tab.group.editor.openDiff(id("sub", .workingTree), as: .pinned)
    waitRows(dirty, "中身だけ変わった") { _ in
      self.text(dirty.newRevision) == "Subproject commit \(first)-dirty"
    }
    XCTAssertEqual(text(dirty.old), "Subproject commit \(first)")
    tab.group.editor.close(.diff(id("sub", .workingTree)))

    XCTAssertTrue(repo.git(["-C", "sub", "commit", "-qam", "inside"]).isSuccess)
    let second = commit()
    pumpMain(until: {
      dirty.files.status?.entries["sub"]?.unstagedSubmodule == .commit(dirty: false)
    })
    let moved = try tab.group.editor.openDiff(id("sub", .workingTree), as: .pinned)
    pumpMain(until: { self.text(moved.newRevision) == "Subproject commit \(second)" }, "中でコミットした")
    XCTAssertEqual(text(moved.old), "Subproject commit \(first)")
    XCTAssertEqual(removedLines(try engine(moved.newSurface).rows), [0], "1 行の差")
    try repo.write("sub/t.txt", "changed again\n")
    pumpMain(
      until: { self.text(moved.newRevision) == "Subproject commit \(second)-dirty" },
      "コミットが動き、中も変わった")

    XCTAssertTrue(repo.git(["add", "sub"]).isSuccess)
    let staged = try tab.group.editor.openDiff(id("sub", .staged), as: .pinned)
    pumpMain(until: { self.text(staged.newRevision) == "Subproject commit \(second)" }, "ステージ済み")
    XCTAssertEqual(text(staged.old), "Subproject commit \(first)")
  }

  /// 作業ツリーのサブモジュールの diff を開いたまま中で続けてコミットすると、新しい側は毎回そのコミットに追う——git dir が
  /// `.git/modules` にある形でも、作業ツリーの中にある形でも。2 回目からは親の status が変わらず、入れ子の git dir の
  /// 知らせだけが届く（中のファイルを書かない空のコミットで、作業ツリーの変化を混ぜない。足したときの変化が収まってから
  /// コミットする）。
  func testASubmoduleDiffFollowsRepeatedCommitsInsideInBothGitDirLayouts() throws {
    let (tab, _) = tab()
    for (path, inTree) in [("sub", false), ("near", true)] {
      try repo.addSubmodule(path, gitDirInWorkingTree: inTree)
      let head = {
        self.repo.git(["-C", path, "rev-parse", "HEAD"]).stdoutText.trimmingCharacters(
          in: .newlines)
      }
      let diff = try tab.group.editor.openDiff(id(path, .workingTree), as: .pinned)
      let first = head()
      pumpMain(until: { self.text(diff.newRevision) == "Subproject commit \(first)" }, path)
      RunLoop.main.run(until: Date().addingTimeInterval(BatchDebounce.maximumDelay * 2))

      for round in 1...2 {
        XCTAssertTrue(
          repo.git(["-C", path, "commit", "-q", "--allow-empty", "-m", "\(round)"]).isSuccess)
        let commit = head()
        pumpMain(
          until: { self.text(diff.newRevision) == "Subproject commit \(commit)" },
          "\(path): \(round) 回目")
      }
    }
  }

  /// サブモジュールをファイルに置き換えた作業ツリー diff は、「Subproject commit」の行とファイルの本文の丸ごとの置き換えで、
  /// 新しい側はファイルの文書。
  func testASubmoduleReplacedByAFileIsAWholeReplacement() throws {
    try repo.addSubmodule("sub")
    let first = repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText.trimmingCharacters(
      in: .newlines)
    try FileManager.default.removeItem(at: repo.url("sub"))
    try repo.write("sub", "a file\nnow\n")
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("sub", .workingTree), as: .pinned)
    waitRows(diff, "置き換え") { self.removedLines($0) == [0] }
    XCTAssertNotNil(diff.document, "新しい側はファイルの文書")
    XCTAssertEqual(text(diff.old), "Subproject commit \(first)")
    let rows = try engine(diff.newSurface).rows
    XCTAssertEqual(rows.style(ofLine: 0), DiffStyle.added)
    XCTAssertEqual(rows.style(ofLine: 2), DiffStyle.added, "全部の行が追加")
  }

  /// index ではファイルのパスを作業ツリーで取り出したリポジトリに置き換え、見せていない間に `git add` してから見せると、
  /// 古い側だけを先に替えず、前の組のまま中の HEAD を待って 1 行どうしに収まる（古い側だけ替わると、並びが古い側の行の
  /// 数と合わず落ちる）。
  func testStagingAFileReplacedByASubmoduleKeepsBothSidesTogether() throws {
    try repo.write("sub", "x\ny\nz\n")
    XCTAssertTrue(repo.git(["add", "sub"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "sub file"]).isSuccess)
    try FileManager.default.removeItem(at: repo.url("sub"))
    try repo.write("sub/t.txt", "t\n")
    for args in [
      ["-C", "sub", "init", "-q", "-b", "main"], ["-C", "sub", "add", "t.txt"],
      ["-C", "sub", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "t"],
    ] {
      XCTAssertTrue(repo.git(args).isSuccess, "\(args)")
    }
    let inner = repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText.trimmingCharacters(
      in: .newlines)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("sub", .workingTree), as: .pinned)
    waitRows(diff, "ファイル → サブモジュールの置き換え") { _ in
      self.text(diff.newRevision) == "Subproject commit \(inner)"
    }
    XCTAssertEqual(text(diff.old), "x\ny\nz\n", "古い側は index のファイル")
    XCTAssertEqual(diff.revisionHunks, [LineHunk(old: 0..<4, new: 0..<1)], "丸ごとの置き換え")
    diff.dismiss()

    XCTAssertTrue(repo.git(["add", "sub"]).isSuccess)
    let index = RootFiles.Version(path: "sub", revision: .index)
    pumpMain(
      until: {
        if case .submodule? = diff.files.state(of: index) { return true }
        return false
      }, "index がサブモジュールになる")
    diff.present(.inline)
    pumpMain(
      until: { diff.revisionHunks.isEmpty && diff.oldSide.lines == 1 }, "中の HEAD が届くと 1 行どうし")

    let staged = try tab.group.editor.openDiff(id("sub", .staged), as: .pinned)
    pumpMain(until: { staged.content == .ready && staged.newRevision != nil }, "ステージ済み")
    XCTAssertEqual(
      staged.revisionHunks, [LineHunk(old: 0..<4, new: 0..<1)], "ステージ済みも丸ごとの置き換え")
  }

  /// 消したファイルの diff を開いたまま、ファイルを別の中身で戻して index に入れ、もう一度消すと、並びは今の index の版の
  /// 全部の行の削除になる。index を元の本文に戻せば、その全部の行の削除に並び直す。
  func testDeletingAFileAgainAfterItsIndexChangedShowsTheNewIndexAsRemoved() throws {
    let (tab, _) = tab()
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "全部の行が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }

    try repo.write("a.txt", "x\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(
      until: { diff.document != nil && diff.oldSource == .some("x\n") }, "前提: 戻した文書と新しい index")
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    waitRows(diff, "新しい index の版の全部の行が削除") { _ in
      diff.document == nil && diff.oldSide.lines == 2
    }
    XCTAssertEqual(removedLines(try engine(diff.newSurface).rows), [0, 1])

    XCTAssertTrue(repo.git(["restore", "--staged", "a.txt"]).isSuccess)
    waitRows(diff, "元の index の版の全部の行が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }
  }

  /// 消したファイルを短い本文で戻して index に入れた後、中にコミットを持つリポジトリのディレクトリに置き換えると、見せた
  /// ままでも、隠している間に置き換えて見せ直しても、並びは今の index の版とサブモジュールの行の丸ごとの置き換えになる。
  /// 中の HEAD を読む間は、前の並びを面に置かない。
  func testReplacingARestoredFileWithARepositoryReplacesTheRowsWholeVisibleOrHidden() throws {
    for hidden in [false, true] {
      if hidden { try setUpWithError() }
      let (tab, _) = tab()
      try FileManager.default.removeItem(at: repo.url("a.txt"))
      let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
      waitRows(diff, "全部の行が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }
      try repo.write("a.txt", "x\n")
      XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
      pumpMain(
        until: { diff.document != nil && diff.oldSource == .some("x\n") && diff.content == .ready },
        "前提: 戻した文書と新しい index")
      if hidden { diff.dismiss() }

      let nested = repo.dir.path + "-nested-\(hidden)"
      for args in [
        ["init", "-q", "-b", "main", nested],
        [
          "-C", nested, "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q",
          "--allow-empty",
          "-m", "t",
        ],
      ] {
        XCTAssertTrue(repo.git(args).isSuccess, "\(args)")
      }
      try FileManager.default.removeItem(at: repo.url("a.txt"))
      try FileManager.default.moveItem(atPath: nested, toPath: repo.root + "/a.txt")
      if hidden {
        let working = try XCTUnwrap(diff.workingTree)
        pumpMain(until: { working.workingStale }, "前提: 隠している間に作業ツリーが変わったと知る")
        diff.present(.inline)
      } else {
        try XCTUnwrap(diff.rootObserver).rootFiles(diff.files, filesDidChange: .scanAll)
      }
      XCTAssertNil(diff.document, "前提: 文書が無くなった")
      XCTAssertTrue(diff.pending, "前提: 中の HEAD を読んでいる")
      XCTAssertEqual(diff.content, .loading, "中の HEAD を読む間は何も出さない")
      XCTAssertNil(diff.newSurface)

      waitRows(diff, hidden ? "見せ直した後の置き換え" : "見せたままの置き換え") { _ in
        diff.document == nil && diff.newRevisionSide.lines == 1
      }
      XCTAssertEqual(diff.revisionHunks, [LineHunk(old: 0..<2, new: 0..<1)], "丸ごとの置き換え")
    }
  }

  private func text(_ revision: RevisionDocument?) -> String? {
    revision.map { String(decoding: $0.text.contiguousUnits(), as: UTF16.self) }
  }
}
