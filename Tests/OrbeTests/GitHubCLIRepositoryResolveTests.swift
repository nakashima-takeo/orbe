import XCTest

@testable import Orbe

/// 正式名の問い合わせ（`GitHubCLI.resolveRepository`）。remote の台帳は、この答えが「正式名」か
/// 「確かめられない」かで、その remote の値を決める。
///
/// 見分けを誤ると、見えない private リポジトリや一時的な失敗が「GitHub の行でない」と読まれ、clean が
/// PR の事実を「確かめて 0 件」と読むか、正式名が返っているのに確かめられないままになる。数字だけの名前が
/// 文字列で渡らないと、そのリポジトリでは問い合わせが失敗し続ける。
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

  /// 答えは出力の JSON で見分ける: 正式名（改名後の名前）があれば正式名、それ以外（存在しない・見えない・
  /// その他のエラー・出力の無い失敗）は確かめられない。
  func testAnswerIsReadFromTheResponseBody() {
    func read(_ text: String) -> GitHubRepositoryResolution {
      GitHubCLI.repositoryResolution(from: Data(text.utf8))
    }
    XCTAssertEqual(
      read(Output.found), .found(GitHubRepoName(nameWithOwner: "vercel/next.js")), "正式名を返す")
    XCTAssertEqual(read(Output.notFound), .unverified, "存在しない（見えない）リポジトリ")
    XCTAssertEqual(read(Output.invalidVariable), .unverified, "存在しない以外のエラー")
    XCTAssertEqual(read(""), .unverified, "出力の無い失敗（起動失敗・打ち切り）")
  }

  /// gh は正式名を返しても非 0 で終わることがあるので、終了コードでなく出力で読む。
  func testCanonicalNameIsReadDespiteNonZeroExit() throws {
    try stageGh(stdout: Output.found, exit: 1)
    XCTAssertEqual(try resolve("o/r"), .found(GitHubRepoName(nameWithOwner: "vercel/next.js")))
  }

  /// gh が答えを返さずに落ちたら確かめられない（次に開いたとき問い直す側）。
  func testFailureWithoutAnAnswerIsUnverified() throws {
    try stageGh(stdout: "", exit: 1)
    XCTAssertEqual(try resolve("o/r"), .unverified)
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

  private func resolve(_ name: String) throws -> GitHubRepositoryResolution {
    var answer: GitHubRepositoryResolution?
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
