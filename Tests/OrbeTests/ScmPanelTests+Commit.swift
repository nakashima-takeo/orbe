import XCTest

@testable import Orbe

/// コミット・amend・コミットしてプッシュの中身（実 git）——押した時点に見えている範囲（このパネルで押してまだ行に出ていない
/// ステージ・解除を重ねる）で、ステージ済みがあればそれだけ、無ければ「変更」の全部。自分が押していない変化がまだ行に
/// 出ていない間に押すと、何も書かずに断る。
///
/// 壊れると何が起きるか。ステージした分だけをコミットしたつもりで、作業中の変更や未追跡（秘密のファイルを含みうる）まで
/// 入り、コミットしてプッシュなら remote にも届く。ステージせずに押したコミットに変更が入らない。パネルで押した ＋・− の
/// 直後のコミットが、自分の操作のせいで「表示と食い違う」と断られる。
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
    panel.commit()
    idle("ステージ済みのコミット")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "s.txt\n")

    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 3 },
      "ステージ済みが無くなる")
    panel.control.message = "all"
    panel.commit()
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

    panel.amend()
    idle("ステージ済みの amend")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits, "積まずに差し替える")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n", "作業中の変更は残る")

    try repo.write("n.txt", "new\n")
    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 2 },
      "ステージ済みが無くなる")
    panel.amend()
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
      var rowsCaughtUp: Bool?
      let staged = panel.changes.staged.count
      let hook = FinishHook(scene.kind) { [panel] in
        guard let panel, scene.afterFinish else { return }
        rowsCaughtUp = panel.changes.staged.count != staged
        panel.commit()
      }
      panel.control.addObserver(hook)
      withExtendedLifetime(hook) {
        panel.press(row, scene.control, in: panel.layout)
        if !scene.afterFinish { panel.commit() }
        pumpMain(
          until: { !scene.afterFinish || rowsCaughtUp != nil }, "\(name): 書き込みが終わる")
        idle("\(name): コミット")
      }
      if scene.afterFinish { XCTAssertEqual(rowsCaughtUp, false, "\(name): 前提: 行はまだ組み直されていない") }
      XCTAssertNil(panel.control.failure, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, scene.left, name)
    }
  }

  /// 自分が押していない変化——端末での `git add` の直後（監視が届いて行に出る前）に押したコミット・amend・コミットして
  /// プッシュは、何も書かずに断る。
  func testCommittingRightAfterAnOutsideChangeIsRefusedAndWritesNothing() throws {
    let actions: [(String, (ScmPanel) -> Void)] = [
      ("commit", { $0.commit() }), ("amend", { $0.amend() }),
      ("commitAndPush", { $0.commitAndPush() }),
    ]
    for (name, act) in actions {
      try freshRepo(addingOrigin: name == "commitAndPush")
      try repo.write("a.txt", "edited\n")
      try repo.write("secret.env", "token\n")
      show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "\(name): 行")
      panel.control.message = "m"
      XCTAssertTrue(repo.git(["add", "secret.env"]).isSuccess)
      let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)
      act(panel)
      idle("\(name): コミット")
      XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch), name)
      XCTAssertEqual(repo.head(), head, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status, name)
    }
  }

  /// 前の場面のパネルを閉じ、新しい repo にする（最初の場面は setUp の repo のまま）。
  private func freshRepo(addingOrigin: Bool) throws {
    if panel != nil {
      panel.isShown = false
      panel.isLive = false
      repo = try TempGitRepo()
    }
    if addingOrigin { repo.addOrigin() }
  }
}

/// 自分の書き込みを押してからコミットする場面。`left` はコミットの後に残る変更。
private struct OwnWriteScene {
  let name: String
  let kind: SourceControl.Kind
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
    kind = control == .unstage ? .unstage : .stage
    self.section = section
    self.path = path
    self.staged = staged
    self.afterFinish = afterFinish
    self.left = left
  }
}

/// `kind` の操作が終わった知らせの中で 1 回だけ `body` を呼ぶ。
@MainActor
private final class FinishHook: SourceControlObserver {
  private let kind: SourceControl.Kind
  private var body: (() -> Void)?

  init(_ kind: SourceControl.Kind, _ body: @escaping () -> Void) {
    self.kind = kind
    self.body = body
  }

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    guard kind == self.kind, let body else { return }
    self.body = nil
    body()
  }
}
