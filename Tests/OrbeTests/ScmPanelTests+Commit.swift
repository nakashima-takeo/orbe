import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミット・amend・コミットしてプッシュの中身（実 git）——押した時点に見えている範囲（このパネルで押してまだ行に出ていない
/// ステージ・解除を重ねる）で、ステージ済みがあればそれだけ、無ければ「変更」の全部。自分が押していない変化がまだ行に
/// 出ていない間に押すと、何も書かずに断る。
///
/// 壊れると何が起きるか。ステージした分だけをコミットしたつもりで、作業中の変更や未追跡（秘密のファイルを含みうる）まで
/// 入り、コミットしてプッシュなら remote にも届く。ステージせずに押したコミットに変更が入らない。パネルで押した ＋・− の
/// 直後や、前に ＋ したファイルをコミットした後のコミットが、自分の操作のせいで「表示と食い違う」と断られる。
extension ScmPanelTests {
  /// コミットの中身は押した時点の姿で決まる——ステージ済みがあればそれだけ、無ければ「変更」の全部（変更・削除・未追跡）。
  func testCommitTakesTheStagedPartOrElseEveryChange() throws {
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    try FileManager.default.removeItem(atPath: repo.root + "/b.txt")
    try repo.write("n.txt", "new\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 3 }, "両方の区分")

    panel.control.message = "staged"
    panel.commitSnapshot().commit()
    idle("ステージ済みのコミット")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "s.txt\n")

    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 3 },
      "ステージ済みが無くなる")
    panel.control.message = "all"
    panel.commitSnapshot().commit()
    idle("全部のコミット")
    XCTAssertEqual(
      repo.git(["show", "--name-status", "--format=", "HEAD"]).stdoutText,
      "M\ta.txt\nD\tb.txt\nA\tn.txt\n")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, "")
  }

  /// amend もコミットと同じ範囲で直前のコミットを差し替える——ステージ済みがあればそれだけ、無ければ「変更」の全部。
  func testAmendTakesTheStagedPartOrElseEveryChange() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 1 }, "両方の区分")
    let commits = repo.git(["rev-list", "--count", "HEAD"]).stdoutText

    panel.commitSnapshot().amend()
    idle("ステージ済みの amend")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits, "積まずに差し替える")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n", "作業中の変更は残る")

    try repo.write("n.txt", "new\n")
    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 2 },
      "ステージ済みが無くなる")
    panel.commitSnapshot().amend()
    idle("全部の amend")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, "")
    XCTAssertEqual(
      repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\nn.txt\ns.txt\n")
  }

  /// このパネルで押した ＋・すべてステージ・− は、走っている・順番を待つ・終わって行に出る前のどの間にコミットを押しても、
  /// 押した結果どおりに数える（押す時刻で結果が変わらない）。
  func testCommittingRightAfterOwnStagingTakesWhatWasPressed() throws {
    let scenes: [OwnWriteScene] = [
      OwnWriteScene("＋ の直後", .stage, .changes, "n.txt", staged: [], left: " M a.txt\n?? m.txt\n"),
      OwnWriteScene(
        "＋ が終わって行に出る前", .stage, .changes, "n.txt", staged: [], afterFinish: true,
        left: " M a.txt\n?? m.txt\n"),
      OwnWriteScene("すべてステージの間", .stageAll, .changes, nil, staged: [], left: ""),
      OwnWriteScene(
        "− の直後", .unstage, .staged, "n.txt", staged: ["n.txt", "m.txt"],
        left: " M a.txt\n?? n.txt\n"),
      OwnWriteScene(
        "− が終わって行に出る前", .unstage, .staged, "n.txt", staged: ["n.txt", "m.txt"],
        afterFinish: true, left: " M a.txt\n?? n.txt\n"),
    ]
    for scene in scenes {
      let name = scene.name
      try freshRepo(addingOrigin: false)
      try repo.write("a.txt", "edited\n")
      try repo.write("n.txt", "new\n")
      try repo.write("m.txt", "new\n")
      if !scene.staged.isEmpty { XCTAssertTrue(repo.git(["add"] + scene.staged).isSuccess) }
      show(
        until: { $0.changes.staged.count == scene.staged.count && $0.changes.changes.count >= 1 },
        "\(name): 行")
      panel.control.message = "m"
      let row = try XCTUnwrap(
        panel.layout.index[ScmRowID(section: scene.section, path: scene.path)], name)
      let press = { (panel: ScmPanel) in _ = panel.press(row, scene.control, in: panel.layout) }
      if scene.afterFinish {
        let staged = panel.changes.staged.count
        pressAfterItFinishes(name, first: press) {
          XCTAssertEqual($0.changes.staged.count, staged, "\(name): 前提: 行はまだ組み直されていない")
          $0.commitSnapshot().commit()
        }
      } else {
        press(panel)
        panel.commitSnapshot().commit()
        idle("\(name): コミット")
      }
      XCTAssertNil(panel.control.failure, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, scene.left, name)
    }
  }

  /// 面を隠している間に終わった自分の ＋ も、出し直して行が組み直される前に押したコミットに数える（隠している間は status
  /// を受けないので、終わった時点の行には出ていない）。
  func testOwnStagingFinishedWhileHiddenStillCounts() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "変更の行")
    let row = try XCTUnwrap(panel.layout.index[ScmRowID(section: .changes, path: "n.txt")])
    panel.press(row, .stage, in: panel.layout)
    panel.isLive = false
    idle("隠している間のステージ")
    panel.isLive = true
    XCTAssertTrue(panel.changes.staged.isEmpty, "前提: 行はまだ組み直されていない")
    panel.control.message = "n"
    panel.commitSnapshot().commit()
    idle("コミット")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n")
  }

  /// 自分の ＋ が行に出た後は、見えている行だけで範囲を決める——＋ でステージしてコミットした後に、ステージせずに押した
  /// コミットは残りの変更を入れる（前の ＋ を持ち越して断らない）。
  func testOwnStagingStopsCountingOnceTheRowsShowIt() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "変更の行")
    let row = try XCTUnwrap(panel.layout.index[ScmRowID(section: .changes, path: "n.txt")])
    panel.press(row, .stage, in: panel.layout)
    idle("ステージ")
    pumpMain(until: { self.panel.changes.staged.map(\.path) == ["n.txt"] }, "n.txt がステージ済みに出る")
    panel.control.message = "n"
    panel.commitSnapshot().commit()
    idle("ステージ済みのコミット")
    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 1 },
      "a.txt だけが残る")

    panel.control.message = "rest"
    panel.commitSnapshot().commit()
    idle("残りのコミット")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
  }

  /// このパネルで押したコミット・amend・取り消し・プルは、終わって行に出る前（プルは走っている間）に次のコミット・amend を
  /// 押しても、押した結果どおりに数える——自分が動かした HEAD を「表示と食い違う」と断らない。
  func testCommittingRightAfterOwnHeadWritesTakesWhatWasPressed() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 1 }, "両方の区分")
    panel.control.message = "s"
    pressRightAfter(
      "コミットの直後のコミット", first: { $0.commitSnapshot().commit() },
      then: {
        $0.control.message = "rest"
        $0.commitSnapshot().commit()
      })
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD~1"]).stdoutText, "s.txt\n")

    let commits = repo.git(["rev-list", "--count", "HEAD"]).stdoutText
    pumpMain(until: { self.panel.changes.count == 0 }, "変更が無くなる")
    panel.control.message = "one"
    pressRightAfter(
      "メッセージだけの amend の直後の amend", first: { $0.commitSnapshot().amend() },
      then: {
        $0.control.message = "two"
        $0.commitSnapshot().amend()
      })
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "two\n")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits)

    let parent = repo.git(["rev-parse", "HEAD~1"]).stdoutText
    pumpMain(until: { self.panel.changes.head == self.repo.head() }, "行が今の HEAD に追いつく")
    pressRightAfter(
      "取り消しの直後のコミット", first: { $0.commitSnapshot().undoLastCommit() },
      then: {
        $0.control.message = "again"
        $0.commitSnapshot().commit()
      })
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["rev-parse", "HEAD~1"]).stdoutText, parent)
    XCTAssertEqual(
      repo.git(["show", "--name-only", "--format=%s", "HEAD"]).stdoutText, "again\n\na.txt\n")
  }

  /// 自分のコミットが終わって行に出る前に外でコミットされると、その後に押した amend は、自分が動かした先と違う HEAD として
  /// 何も書かずに断る。
  func testAnOutsideCommitRightAfterOwnCommitIsRefused() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("z.txt", "agent\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 1 }, "両方の区分")
    panel.control.message = "a"
    var outside = ""
    let repo = self.repo!
    pressRightAfter(
      "自分のコミットの直後の外のコミット", first: { $0.commitSnapshot().commit() },
      then: {
        XCTAssertTrue(repo.git(["add", "z.txt"]).isSuccess)
        XCTAssertTrue(repo.git(["commit", "-qm", "agent"]).isSuccess)
        outside = repo.head()
        $0.control.message = "reword"
        $0.commitSnapshot().amend()
      })
    XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch))
    XCTAssertEqual(repo.head(), outside)
  }

  /// 自分の取り消しが終わる前に、監視の知らせによる取り直しで行が先に追いついても、終わった後に押したコミットは押したとおりに
  /// 数える。既に行に出ている取り消しを、もう 1 回重ねない（重ねると、見えていた HEAD が 1 代ずれて断る）。
  func testCommittingAfterOwnUndoThatTheRowsShowedBeforeItFinishedTakesWhatWasPressed() throws {
    try repo.write("u.txt", "undone\n")
    XCTAssertTrue(repo.git(["add", "u.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "undone"]).isSuccess)
    let parent = repo.git(["rev-parse", "HEAD~1"]).stdoutText.trimmingCharacters(in: .newlines)
    show(until: { $0.changes.head == self.repo.head() }, "行が今の HEAD に揃う")
    // 取り消しがブランチを戻した後、git が返る前で止める。hook は ref の更新のたびに呼ばれるので、足場の git の後に有効にする。
    let hook = try GitHangFixture()
    try hook.installScript(
      "reference-transaction",
      body: """
        [ "$1" = committed ] || exit 0
        grep -q ' refs/heads/main$' || exit 0
        \(hook.waitingBody)
        """)
    XCTAssertTrue(repo.git(["config", "core.hooksPath", hook.dir.path]).isSuccess)

    panel.commitSnapshot().undoLastCommit()
    XCTAssertTrue(hook.pumpUntilHung(), "前提: 取り消しがブランチを戻したところで止まる")
    pumpMain(until: { self.panel.changes.head == parent }, "行が取り消しの後の HEAD に追いつく")
    XCTAssertFalse(panel.control.operations.isEmpty, "前提: 取り消しはまだ終わっていない")
    hook.release()
    idle("取り消し")
    panel.control.message = "again"
    panel.commitSnapshot().commit()
    idle("コミット")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["rev-parse", "HEAD~1"]).stdoutText, parent + "\n")
    XCTAssertEqual(
      repo.git(["show", "--name-only", "--format=%s", "HEAD"]).stdoutText, "again\n\nu.txt\n")
  }

  /// 走っているプルの後ろで押したコミットは、プルが動かした HEAD の上に、見えていたステージ済みをコミットする。
  func testCommittingWhileOwnPullRunsCommitsOnThePulledHead() throws {
    repo.addOrigin()
    try repo.advanceOrigin(writing: "o.txt", "other\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 }, "ステージ済み")
    panel.control.message = "s"
    panel.pull()
    panel.commitSnapshot().commit()
    idle("プルとコミット")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(
      repo.git(["rev-parse", "HEAD~1"]).stdoutText,
      repo.git(["rev-parse", "origin/main"]).stdoutText)
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "s.txt\n")
  }

  /// `first` で始めた操作が終わった後、行が新しい HEAD に追いつく前に `then` を押し、終わるまで回す（→ `pressAfterItFinishes`）。
  func pressRightAfter(_ name: String, first: (ScmPanel) -> Void, then: (ScmPanel) -> Void) {
    let head = panel.changes.head
    pressAfterItFinishes(name, first: first) {
      XCTAssertEqual($0.changes.head, head, "\(name): 前提: 行はまだ前の HEAD のまま")
      then($0)
    }
  }

  /// `first` を押し、その操作が終わった後、行が組み直される前の周で `then` を呼び、終わるまで回す。押した周でパネルを隠して
  /// 行の組み直しを止め（面は見えたままなので、status は受け続ける）、終わった後に出し直した周で `then` を呼ぶ。出し直しは
  /// 組み直しを裏へ頼むだけなので、その周の行は、監視の知らせがいつ届いても押す前の姿のまま。
  func pressAfterItFinishes(_ name: String, first: (ScmPanel) -> Void, then: (ScmPanel) -> Void) {
    first(panel)
    panel.isShown = false
    idle("\(name): 書き込みが終わる")
    panel.isShown = true
    then(panel)
    idle("\(name): 次の書き込み")
  }
}

/// 自分の書き込みを押してからコミットする場面。`left` はコミットの後に残る変更。
private struct OwnWriteScene {
  let name: String
  let control: ScmControl
  let section: ScmSection
  let path: String?
  let staged: [String]
  let afterFinish: Bool
  let left: String

  init(
    _ name: String, _ control: ScmControl, _ section: ScmSection, _ path: String?,
    staged: [String], afterFinish: Bool = false, left: String
  ) {
    self.name = name
    self.control = control
    self.section = section
    self.path = path
    self.staged = staged
    self.afterFinish = afterFinish
    self.left = left
  }
}
