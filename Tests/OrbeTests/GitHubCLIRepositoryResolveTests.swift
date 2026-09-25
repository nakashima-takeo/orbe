import XCTest

@testable import Orbe

/// 正式名の問い合わせ（`GitHubCLI.resolveRepository`）。remote の台帳は、この答えが「正式名」
/// 「存在しない」「分からなかった」のどれかで確定・失敗を決める。
///
/// 見分けを誤ると、存在しない remote のせいで台帳が永久に失敗のまま（PR がローディングのまま）になるか、
/// 一時的な失敗が「GitHub の行でない」と確定してキャッシュに焼かれ、そのリポジトリでは次に開いても
/// チップが出ず clean が PR の事実を失う。数字だけの名前が文字列で渡らないと、そのリポジトリでは
/// 問い合わせが失敗し続ける。
final class GitHubCLIRepositoryResolveTests: OrbeTestCase {
  private var dir: URL?

  override func tearDownWithError() throws {
    if let dir { try? FileManager.default.removeItem(at: dir) }
  }

  /// 実 gh の出力（2026-09 に実測）。
  private enum Output {
    static let found = #"{"data":{"repository":{"nameWithOwner":"vercel/next.js"}}}"#
    static let notFound = """
      {"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],\
      "locations":[{"line":1,"column":30}],"message":"Could not resolve to a Repository with the \
      name 'o/missing'."}]}
      """
    /// 変数の型が合わないときの応答（`-F` で数字だけの名前を渡すと返る）。
    static let invalidVariable = """
      {"errors":[{"extensions":{"value":2048,"problems":[{"path":[],"explanation":"Could not \
      coerce value 2048 to String"}]},"locations":[{"line":1,"column":18}],"message":"Variable \
      $n of type String! was provided invalid value"}]}
      """
  }

  /// owner と name は文字列のまま（`-f`）渡す——`-F` は数字だけの名前を整数に変え、問い合わせが
  /// 失敗し続ける。ホストは認証確認と同じ github.com を名指しする。
  func testQueryPassesOwnerAndNameAsStringsToGitHubDotCom() throws {
    let arguments = GitHubCLI.resolveRepositoryArguments(
      GitHubRepoName(nameWithOwner: "gabrielecirulli/2048"))
    XCTAssertEqual(Array(arguments.prefix(4)), ["api", "graphql", "--hostname", "github.com"])
    for field in ["o=gabrielecirulli", "n=2048"] {
      let index = try XCTUnwrap(arguments.firstIndex(of: field), "\(field) を渡す")
      XCTAssertEqual(arguments[index - 1], "-f", "\(field) は文字列として渡す")
    }
  }

  /// 答えは出力の JSON で見分ける: 正式名（改名後の名前）・存在しない・それ以外は分からなかった。
  func testAnswerIsReadFromTheResponseBody() {
    func read(_ text: String) -> GitHubRepositoryResolution? {
      GitHubCLI.repositoryResolution(from: Data(text.utf8))
    }
    XCTAssertEqual(
      read(Output.found), .found(GitHubRepoName(nameWithOwner: "vercel/next.js")), "正式名を返す")
    XCTAssertEqual(read(Output.notFound), .notFound, "存在しないリポジトリは存在しないと確定")
    XCTAssertNil(read(Output.invalidVariable), "存在しない以外のエラーは分からなかった")
    XCTAssertNil(read(""), "出力の無い失敗（起動失敗・打ち切り）は分からなかった")
  }

  /// gh は存在しないリポジトリでも非 0 で終わるが、それを「分からなかった」にしない。
  func testMissingRepositoryIsNotFoundDespiteNonZeroExit() throws {
    try stageGh(stdout: Output.notFound, exit: 1)
    XCTAssertEqual(try resolve("o/missing"), .notFound)
  }

  /// gh が答えを返さずに落ちたら「分からなかった」（次に開いたとき問い合わせ直せる側）。
  func testFailureWithoutAnAnswerIsUnknown() throws {
    try stageGh(stdout: "", exit: 1)
    XCTAssertNil(try resolve("o/r"))
  }

  // MARK: - ヘルパ

  /// 決まった出力と終了コードを返す偽 `gh` を PATH に置く。
  private func stageGh(stdout: String, exit: Int32) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-gh-resolve-\(UUID().uuidString)")
    self.dir = dir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = dir.appendingPathComponent("body.json").path
    try stdout.write(toFile: body, atomically: true, encoding: .utf8)
    let gh = dir.appendingPathComponent("gh").path
    try "#!/bin/sh\ncat \"\(body)\"\nexit \(exit)\n".write(
      toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
  }

  private func resolve(_ name: String) throws -> GitHubRepositoryResolution? {
    var answer: GitHubRepositoryResolution??
    let done = expectation(description: "resolveRepository")
    GitHubCLI().resolveRepository(
      cwd: try XCTUnwrap(dir).path, name: GitHubRepoName(nameWithOwner: name)
    ) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return try XCTUnwrap(answer, "答えが返らない")
  }
}
