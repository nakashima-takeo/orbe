import XCTest

@testable import Orbe

/// プロジェクト検索のディスク側の読み——git grep の `-z -n` の出力を、塊の境で割れた行を持ち越して行へ割り（パスは NUL で
/// 区切るので `\n` を含んでよい。UTF-8 でないバイトは置換文字、行末の `\r` は残し、1 行目の先頭の BOM は外す）、終わり方を
/// 問いのエラーに読む（止めた・一致なしはエラーにしない）。
///
/// 壊れると何が起きるか。塊の境に掛かった行が欠けたり 2 つに割れたりする。名前に改行を含むファイルで以後の行がずれる。
/// 1 バイトの不正な UTF-8 でその行の一致が消える。BOM 付きのファイルを開くと 1 行目の一致が 1 字ずれる。止めた検索や一致の
/// 無い検索に「git が断った」が出る。
final class GitGrepTests: OrbeTestCase {
  private static let bom = Data([0xEF, 0xBB, 0xBF])

  private func record(_ path: String, _ number: Int, _ text: Data) -> Data {
    Data(path.utf8) + Data([0]) + Data(String(number).utf8) + Data([0]) + text + Data([0x0A])
  }

  private var output: Data {
    record("a.txt", 1, Self.bom + Data("first".utf8))
      + record("we\nird.txt", 2, Data("crlf\r".utf8))
      + record("bad.txt", 3, Data([0x61, 0xFF, 0x62]))
      + record("b.txt", 2, Self.bom + Data("kept".utf8))
  }

  private let expected = [
    GitGrep.Line(path: "a.txt", number: 1, text: "first"),
    GitGrep.Line(path: "we\nird.txt", number: 2, text: "crlf\r"),
    GitGrep.Line(path: "bad.txt", number: 3, text: "a\u{FFFD}b"),
    GitGrep.Line(path: "b.txt", number: 2, text: "\u{FEFF}kept"),
  ]

  func testLinesAreReadFromRecordsWhateverTheChunking() {
    var whole = GitGrep.Parser()
    XCTAssertEqual(whole.feed(output), expected)

    var byteByByte = GitGrep.Parser()
    var lines: [GitGrep.Line] = []
    for byte in output { lines += byteByByte.feed(Data([byte])) }
    XCTAssertEqual(lines, expected, "塊の境で割れた行は持ち越して 1 行に読む")
  }

  private func ended(
    _ ending: GitRunner.Ending, status: Int32 = 0, stderr: String = ""
  ) -> GitRunner.Output {
    GitRunner.Output(
      status: status, stdout: Data(), stderr: Data(stderr.utf8), ending: ending,
      exited: ending != .launchFailed)
  }

  /// 一致あり（0）・一致なし（1）・止めたはエラーにしない。起動できなければ専用の文、それ以外の失敗は stderr の最初の行。
  func testTheEndingIsReadAsAQueryError() {
    XCTAssertNil(GitGrep.failure(of: ended(.completed, status: 0)))
    XCTAssertNil(GitGrep.failure(of: ended(.completed, status: 1)))
    XCTAssertNil(GitGrep.failure(of: ended(.cancelled, status: 15)), "止めた検索は断られたのではない")
    XCTAssertEqual(
      GitGrep.failure(of: ended(.launchFailed, status: -1, stderr: "no such directory\n")),
      .couldNotStart)
    XCTAssertEqual(
      GitGrep.failure(of: ended(.completed, status: 128, stderr: "fatal: bad pattern\nusage\n")),
      .refused("fatal: bad pattern"))
    XCTAssertEqual(GitGrep.failure(of: ended(.completed, status: 2)), .refused("git grep 2"))
  }
}
