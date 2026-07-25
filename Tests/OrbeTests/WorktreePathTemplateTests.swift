import XCTest

@testable import Orbe

/// worktree 作成先テンプレート（`WorktreePathTemplate`）の検証・解決と、
/// 設定基盤への合流（`SettingDomain.validate` 経由＝パレット・orb config・control の唯一の検証点）の検証。
final class WorktreePathTemplateTests: XCTestCase {

  // MARK: - resolve（置換・~ 展開・standardize）

  func testResolveReplacesAllPlaceholders() {
    XCTAssertEqual(
      WorktreePathTemplate.resolve(
        template: "{parent}/wt/{repo}/{slug}", repoPath: "/Users/x/github/orbe", slug: "feat-x"),
      "/Users/x/github/wt/orbe/feat-x")
  }

  /// `{repo_path}` は repo 本体の場所＝`{parent}/{repo}` と同値に解決する（往復せず一息で書ける）。
  func testResolveRepoPathEqualsParentSlashRepo() {
    XCTAssertEqual(
      WorktreePathTemplate.resolve(
        template: "{repo_path}/.worktrees/{slug}", repoPath: "/Users/x/github/orbe", slug: "feat-x"),
      "/Users/x/github/orbe/.worktrees/feat-x")
    XCTAssertEqual(
      WorktreePathTemplate.resolve(
        template: "{repo_path}/.worktrees/{slug}", repoPath: "/Users/x/github/orbe", slug: "s"),
      WorktreePathTemplate.resolve(
        template: "{parent}/{repo}/.worktrees/{slug}", repoPath: "/Users/x/github/orbe", slug: "s"))
  }

  func testResolveExpandsLeadingTilde() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(
      WorktreePathTemplate.resolve(
        template: "~/wt/{repo}/{slug}", repoPath: "/p/orbe", slug: "feat-x"),
      "\(home)/wt/orbe/feat-x")
  }

  func testResolveStandardizesPath() {
    XCTAssertEqual(
      WorktreePathTemplate.resolve(template: "{parent}//wt/./{slug}", repoPath: "/p/r", slug: "s"),
      "/p/wt/s", "重複スラッシュ・`.` は standardize で畳む")
  }

  /// 既定テンプレートは従来のハードコード規則 `<親>/<repo名>-worktrees/<slug>` と同一パスに解決する
  /// （未設定時の byte 単位互換の要）。
  func testDefaultTemplateMatchesLegacyRule() {
    XCTAssertEqual(
      WorktreePathTemplate.resolve(
        template: WorktreePathTemplate.defaultTemplate, repoPath: "/Users/x/github/orbe",
        slug: "issue-42"),
      "/Users/x/github/orbe-worktrees/issue-42")
  }

  /// 正規化は字句だけ（`.`・`..`・重複/末尾スラッシュを畳む）。
  func testLexicallyStandardizedFoldsPathSyntax() {
    XCTAssertEqual(
      WorktreePathTemplate.lexicallyStandardized("/private/tmp/r/wt/"), "/private/tmp/r/wt")
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized("/a//b/./c"), "/a/b/c")
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized("/a/b/../c"), "/a/c")
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized("/a/../../b"), "/b", "絶対の /.. は /")
  }

  /// 相対の先頭 `..` は畳めない——落とすと repo の外を指すテンプレートが中を指すものに反転する。
  func testLexicallyStandardizedKeepsLeadingParentRefs() {
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized("../a/b"), "../a/b")
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized("a/../../b"), "../b")
  }

  /// **実在する**パスでも symlink を解決せず `/private` を畳まない（Foundation の `standardizingPath`
  /// はここで畳む）。実在する repo root と、これから作る worktree パスを同じ土俵で比べる前提。
  func testLexicallyStandardizedKeepsPrivatePrefixOnExistingPath() throws {
    let dir = URL(fileURLWithPath: "/private/tmp/orbe-std-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertEqual((dir.path as NSString).standardizingPath, "/tmp" + dir.path.dropFirst(12))
    XCTAssertEqual(WorktreePathTemplate.lexicallyStandardized(dir.path), dir.path)
  }

  // MARK: - プリセット

  /// 一覧から選んだ値が保存を拒否されないこと、先頭が既定テンプレート自身であること。
  func testPresetsAreValidAndLedByDefault() {
    XCTAssertEqual(
      WorktreePathTemplate.presets.first?.template, WorktreePathTemplate.defaultTemplate)
    XCTAssertEqual(
      WorktreePathTemplate.presets[2].template, "{repo_path}/.worktrees/{slug}",
      "repo 内配置は親へ上がって名前で降り直さず `{repo_path}` で一息に書く")
    for preset in WorktreePathTemplate.presets {
      XCTAssertNil(WorktreePathTemplate.validate(preset.template), preset.template)
    }
    XCTAssertEqual(
      Set(WorktreePathTemplate.presets.map(\.template)).count, WorktreePathTemplate.presets.count,
      "同じテンプレートの行を二重に出さない")
  }

  // MARK: - validate

  func testValidateAcceptsDefaultTemplate() {
    XCTAssertNil(WorktreePathTemplate.validate(WorktreePathTemplate.defaultTemplate))
  }

  func testValidateAcceptsTildeTemplate() {
    XCTAssertNil(WorktreePathTemplate.validate("~/wt/{repo}/{slug}"))
  }

  /// repo 内配置は `{repo_path}/...`（`{parent}/{repo}/...` でも同義）と明示的に書ける。
  func testValidateAcceptsInRepoTemplate() {
    XCTAssertNil(WorktreePathTemplate.validate("{repo_path}/.worktrees/{slug}"))
    XCTAssertNil(WorktreePathTemplate.validate("{parent}/{repo}/.worktrees/{slug}"))
  }

  /// repo を区別する語の判定（提示側の警告が読む）。`{repo_path}` も repo 固有なので衝突しない。
  func testDistinguishesRepository() {
    XCTAssertTrue(WorktreePathTemplate.distinguishesRepository("{parent}/{repo}-worktrees/{slug}"))
    XCTAssertTrue(WorktreePathTemplate.distinguishesRepository("{repo_path}/.worktrees/{slug}"))
    XCTAssertFalse(WorktreePathTemplate.distinguishesRepository("~/wt/{slug}"))
  }

  func testValidateRejectsUnknownToken() {
    XCTAssertEqual(
      WorktreePathTemplate.validate("/wt/{branch}/{slug}"), .unknownToken("{branch}"))
  }

  func testValidateRejectsUnclosedBrace() {
    XCTAssertEqual(WorktreePathTemplate.validate("/wt/{slug}/{repo"), .unknownToken("{repo"))
  }

  /// `{slug}` を含まないテンプレートは全 branch が同一パスへ落ちるため拒否する。
  func testValidateRejectsMissingSlug() {
    XCTAssertEqual(WorktreePathTemplate.validate("/wt/{repo}"), .missingSlug)
  }

  /// 相対解決の曖昧さは持ち込まない（`{parent}`/`~` 始まり以外で相対に落ちる形は拒否）。
  func testValidateRejectsRelativePath() {
    XCTAssertEqual(WorktreePathTemplate.validate("wt/{slug}"), .notAbsolute)
    XCTAssertEqual(WorktreePathTemplate.validate("{slug}/wt"), .notAbsolute)
  }

  /// 空文字は値として不正（解除は unset／パレットの空確定が担う）。
  func testValidateRejectsEmpty() {
    XCTAssertNotNil(WorktreePathTemplate.validate(""))
  }

  // MARK: - 設定基盤への合流（control/CLI と同じ 1 経路）

  /// `SettingChange(key:jsonValue:)`（config_set・orb config set の検証点）がテンプレート検証を通す。
  func testSettingChangeValidatesTemplate() {
    XCTAssertNotNil(
      SettingChange(key: "worktree-dir", jsonValue: "~/wt/{repo}/{slug}"), "妥当なテンプレートは受理")
    XCTAssertNotNil(
      SettingChange(key: "worktree-dir", jsonValue: "{repo_path}/.worktrees/{slug}"),
      "{repo_path} も既知の語として受理")
    XCTAssertNil(
      SettingChange(key: "worktree-dir", jsonValue: "~/wt/{repo}"), "{slug} 欠落は拒否")
    XCTAssertNil(SettingChange(key: "worktree-dir", jsonValue: "wt/{slug}"), "相対解決は拒否")
    XCTAssertNil(SettingChange(key: "worktree-dir", jsonValue: ""), "空文字は拒否")
    XCTAssertNil(SettingChange(key: "worktree-dir", jsonValue: 42), "型不一致は拒否")
    XCTAssertNotNil(
      SettingChange(key: "worktree-dir", jsonValue: NSNull()), "null は解除（継承へ）として受理")
  }
}
