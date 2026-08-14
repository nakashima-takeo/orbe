import XCTest

@testable import Orbe

/// 実 git 層の「消してコミットが世界に残るか」の判定（3 段構え）。中心は 3 つの実測——
/// **到達性（第0段）だけが統合先の知識なしに非既定ブランチ統合（git-flow）を拾える**こと、
/// **その到達性が信頼してよいのは Orbe が prune する origin だけ**であること、
/// **素の `git cherry` では multi-commit squash を検出できない**（第1段→第2段が要る）こと。
extension GitWorktreeCleanIntegrationTests {

  /// **squash 検出の直接の証拠**。2 コミットを squash マージしたブランチについて、
  /// `git branch --merged` は返さず・`rev-list --count` は 2・**素の `git cherry` も `+` を 2 本**返すのに、
  /// 2 段構え（第1段→第2段）の判定は `.patchEquivalent` を返す。
  /// remote が無いので第0段（到達不能数＝全履歴）は素通りし、従来経路が生きていることの固定でもある。
  func testSquashMergedBranchIsDetectedAsMerged() throws {
    try makeSquashMergedBranch()

    XCTAssertFalse(
      git(["branch", "--merged", "main"]).stdoutText.contains("feat/squash"),
      "前提: 到達性では取り込み済みに見えない")
    XCTAssertEqual(
      git(["rev-list", "--count", "main..feat/squash"]).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines), "2",
      "前提: main から見て 2 コミット未取り込みに見える")
    XCTAssertEqual(
      git(["cherry", "main", "feat/squash"]).stdoutText.split(separator: "\n")
        .filter { $0.hasPrefix("+") }.count, 2,
      "前提: 素の cherry は畳んだ patch-id を照合できず 2 本とも未取り込みと誤判定する")

    XCTAssertEqual(try containment("feat/squash"), .patchEquivalent, "2 段構えなら取り込み済みと判定できる")
  }

  /// 本当に未マージのブランチは独自コミット件数を返す（safe 群に入れない）。
  func testUnmergedBranchReportsOwnCommitCount() throws {
    try makeSquashMergedBranch()
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/live", "main"]).isSuccess)
    try write("d.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "u1"]).isSuccess)
    try write("d.txt", "12")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "u2"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)

    XCTAssertEqual(try containment("feat/live"), .unmerged(count: 2))
  }

  /// 既定ブランチの厳密な祖先（＝完全に取り込み済み）で偽陽性を出さない。
  /// 累積差分のレシピ**単独**では空パッチのダングリングコミットになり `+` を返してしまうため、
  /// 素の cherry を先に置く順序がここで効いている。remote が無いのでラベルは `.patchEquivalent`。
  func testAncestorBranchIsMerged() throws {
    let initial = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try makeSquashMergedBranch()
    XCTAssertTrue(git(["branch", "feat/ancestor", initial]).isSuccess)

    XCTAssertEqual(try containment("feat/ancestor"), .patchEquivalent)
  }

  /// **完了条件の中核（git-flow 再現）**。統合先が既定ブランチでない（develop へマージコミットで統合し
  /// remote ブランチは撤去済み）ブランチは、`origin/main` との cherry では「独自コミット N 件」に
  /// 見えるのに、第0段の到達性が「消してもコミットは remote に残る」を証明する。
  /// 既定ブランチは tip を含まないので「merged → main」は名乗れない（`mergedIntoDefault: false`）。
  func testGitFlowMergeIntoDevelopIsReachableWithoutClaimingMerged() throws {
    XCTAssertTrue(git(["branch", "develop"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/flow", "develop"]).isSuccess)
    try write("f.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "f1"]).isSuccess)
    try write("f.txt", "12")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "f2"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "develop"]).isSuccess)
    XCTAssertTrue(git(["merge", "-q", "--no-ff", "-m", "merge feat/flow", "feat/flow"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    // feature ブランチ自体は push しない＝remote 側で撤去済み（[gone]）の形。
    try addOrigin(pushing: ["main", "develop"])

    XCTAssertEqual(
      git(["cherry", "main", "feat/flow"]).stdoutText.split(separator: "\n")
        .filter { $0.hasPrefix("+") }.count, 2,
      "前提: 既定ブランチとの cherry では 2 コミット未取り込みに見える（従来の誤表示の形）")

    XCTAssertEqual(
      try containment("feat/flow"), .reachable(mergedIntoDefault: false),
      "統合先がどこであれ、全コミットが remote-tracking ref から到達可能なら安全")
  }

  /// 既定ブランチが tip を含む（厳密な祖先）行は、到達性に加えて「merged → main」を名乗れる。
  func testAncestorOfPushedDefaultIsReachableAndNamesMerged() throws {
    let initial = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try write("m.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "m1"]).isSuccess)
    XCTAssertTrue(git(["branch", "feat/old", initial]).isSuccess)
    try addOrigin(pushing: ["main"])

    XCTAssertEqual(try containment("feat/old"), .reachable(mergedIntoDefault: true))
  }

  /// **`unmerged` の count は min（到達不能数, patch 非等価数）**。既定ブランチが統合ブランチより
  /// 遅れたリポジトリでは cherry の `+` が「統合ブランチの先行分」まで膨らむ（+106 型の巨大数）が、
  /// remote に無いのは自分の 2 コミットだけ——真に失われうる数の、より良い過大評価を返す。
  func testUnmergedCountIsTheMinOfUnreachableAndPatchDistance() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "develop"]).isSuccess)
    for i in 1...3 {
      try write("d.txt", String(repeating: "d", count: i))
      XCTAssertTrue(git(["add", "-A"]).isSuccess)
      XCTAssertTrue(git(["commit", "-qm", "d\(i)"]).isSuccess)
    }
    try addOrigin(pushing: ["main", "develop"])
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/min", "develop"]).isSuccess)
    for i in 1...2 {
      try write("u.txt", String(repeating: "u", count: i))
      XCTAssertTrue(git(["add", "-A"]).isSuccess)
      XCTAssertTrue(git(["commit", "-qm", "u\(i)"]).isSuccess)
    }
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)

    XCTAssertEqual(
      git(["cherry", "main", "feat/min"]).stdoutText.split(separator: "\n")
        .filter { $0.hasPrefix("+") }.count, 5,
      "前提: 既定ブランチとの cherry は develop の先行 3 件まで数えて 5 と出る")

    XCTAssertEqual(
      try containment("feat/min"), .unmerged(count: 2), "remote に無い 2 コミットだけを名乗る")
  }

  /// **到達性が信頼するのは origin だけ**。Orbe が prune するのは origin なので、他 remote の
  /// tracking ref は remote 側で消えた後もローカルに残り続ける。それを根拠に安全と読むと、
  /// `[gone]` で安全群に入った行が stale な ref だけを頼りにブランチごと消え、ユーザーが後で
  /// 全 remote を prune した時点でコミットが到達不能になる。
  func testReachabilityTrustsOriginOnlyAndIgnoresOtherRemotes() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/fork"]).isSuccess)
    for i in 1...2 {
      try write("k.txt", String(repeating: "k", count: i))
      XCTAssertTrue(git(["add", "-A"]).isSuccess)
      XCTAssertTrue(git(["commit", "-qm", "k\(i)"]).isSuccess)
    }
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    try addOrigin(pushing: ["main"])
    // fork にだけ feat/fork がある＝origin から見れば失われるコミット。
    try addRemote(named: "fork", pushing: ["feat/fork"])

    XCTAssertEqual(
      git(["rev-list", "--count", "feat/fork", "--not", "--remotes", "--"]).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines), "0",
      "前提: 全 remote を信じると到達可能に見える（stale ref を安全の根拠にしてしまう形）")

    XCTAssertEqual(
      try containment("feat/fork"), .unmerged(count: 2),
      "origin に無いコミットは、他 remote に在っても安全と読まない")
  }

  /// **同名タグに判定を奪われない。** git の短縮名解決は refs/tags が refs/heads より**先**なので、
  /// ブランチと同名のタグ（`v1.0` をタグとブランチの両方に切る運用等）があると、短縮名の判定は
  /// タグの指すコミットを見る——取り込み済みのブランチが、タグの指す未マージコミットの顔で
  /// 「独自コミット N 件」を名乗る。プローブは完全 ref（`refs/heads/<branch>`）を渡すので奪われない。
  func testBranchShadowedByASameNameTagIsJudgedByItsOwnRef() throws {
    let initial = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try write("m.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "m1"]).isSuccess)
    // ブランチ v1.0 は main の祖先（取り込み済み）。worktree としてチェックアウトしておく。
    let wt = dir.appendingPathComponent("wt-v1").path
    XCTAssertTrue(git(["worktree", "add", "-q", "-b", "v1.0", wt, initial]).isSuccess)
    // 同名タグは未マージのコミット（feat/stray の先端）を指す。
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/stray", "main"]).isSuccess)
    try write("s.txt", "s")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "s1"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    XCTAssertTrue(git(["tag", "v1.0", "feat/stray"]).isSuccess)
    try addOrigin(pushing: ["main"])

    XCTAssertEqual(
      git(["rev-parse", "--verify", "v1.0"]).stdoutText.trimmingCharacters(
        in: .whitespacesAndNewlines),
      git(["rev-parse", "--verify", "feat/stray"]).stdoutText.trimmingCharacters(
        in: .whitespacesAndNewlines),
      "前提: 短縮名 v1.0 はブランチではなくタグ（未マージコミット）に解決される")
    XCTAssertEqual(
      try containment("v1.0"), .unmerged(count: 1),
      "前提: 短縮名で判定すると、タグの指す未マージコミットの顔になる（曖昧さの実証）")

    XCTAssertEqual(
      try containment("refs/heads/v1.0"), .reachable(mergedIntoDefault: true),
      "完全 ref ならブランチ自身が判定される")
    XCTAssertEqual(
      try proberContainment(ofWorktreeNamed: "wt-v1"), .reachable(mergedIntoDefault: true),
      "プローブ経由（本番経路）でも同名タグに奪われない")
  }

  /// プローブ（`DispatchCleanProber`）を本物の worktree 一覧で回し、対象 worktree の判定を返す。
  /// パスの突き合わせは末尾名で行う（macOS の /var → /private/var 正規化で完全一致が揺れる）。
  private func proberContainment(ofWorktreeNamed name: String) throws -> GitBranchContainment? {
    var probes: [String: DispatchCleanProbe] = [:]
    let done = expectation(description: "probe")
    repo.worktrees { worktrees in
      DispatchCleanProber(repo: self.repo, defaultBranch: "main")
        .probe(worktrees: worktrees, panes: []) {
          probes = $0
          done.fulfill()
        }
    }
    wait(for: [done], timeout: 20)
    return probes.first { ($0.key as NSString).lastPathComponent == name }?.value.containment
  }

  /// **`rev-list` は pathspec も取る**ので、リポジトリ直下のエントリと同名のブランチ（`docs` 等）は
  /// オプションを終端しないと `ambiguous argument` で落ちる。cwd は main worktree なので、
  /// 終端が無いとその worktree だけ到達性の判定が黙って失敗し、旧経路へ退行する。
  func testBranchNamedAfterATrackedPathStillResolves() throws {
    let initial = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try write("docs/guide.md", "g")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "docs"]).isSuccess)
    XCTAssertTrue(git(["branch", "docs", initial]).isSuccess)
    try addOrigin(pushing: ["main"])

    XCTAssertEqual(
      git(["rev-list", "--count", "docs", "--not", "--remotes=origin"]).isSuccess, false,
      "前提: 終端しないと rev と path の両方に読めて git が解決を拒む")

    XCTAssertEqual(
      try containment("docs"), .reachable(mergedIntoDefault: true),
      "パスと同名でも到達性を判定できる")
  }

}
