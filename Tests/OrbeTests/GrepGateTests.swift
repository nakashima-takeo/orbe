import OrbeTestSupport
import XCTest

@testable import Orbe

/// `GrepGate` の契約: 開くまでは、除外ファイルを開く git を止めておき、開いた後は、後から来た git も止めない。
///
/// 門で止まるのは git grep だけではない。除外ファイルを読む git（開いた文書の根の status など）も、同じ門で止まる。開いた時点で門に
/// 着いていない git grep が、開いた後に門へ着いて止まると、検索が終わらず、プロジェクト検索のテストが上限まで待って落ちる。
final class GrepGateTests: OrbeTestCase {
  /// 裏のスレッドで、リポジトリの status を取る（除外ファイルを開くので、閉じた門で止まる）。
  private final class Status: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var isDone: Bool { lock.withLock { ended } }

    init(_ repo: TempGitRepo) {
      DispatchQueue.global().async { [self] in
        _ = repo.git(["status", "--porcelain"])
        lock.withLock { ended = true }
      }
    }
  }

  func testAGitArrivingAfterTheGateOpensIsNotStopped() throws {
    let repo = try TempGitRepo(name: "orbe-gate")
    let gate = try GrepGate(repo)
    defer { gate.close() }
    let early = Status(repo)
    gate.open()
    XCTAssertTrue(sleepUntil(10) { early.isDone }, "前提: 門で待っていた git が通る")

    let late = Status(repo)
    XCTAssertTrue(sleepUntil(10) { late.isDone }, "開いた後に門へ着いた git も止めない")
  }
}
