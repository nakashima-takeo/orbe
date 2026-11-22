import Foundation
import XCTest

// テストの待ちの唯一の実装。どれも、テストが走る main のスレッドで呼ぶ。
// 否定条件の確かめ方の順（docs/testing/test-architecture.md の「待ち」）との対応は、関数ごとに書く。

/// 条件が成り立つまでランループを回して待ち、期限までに成り立ったかを返す。
///
/// 先に条件を見るので、既に成り立っていればランループを回さない。ランループは、main のキューの仕事などの
/// 入力源を 1 つ処理すると戻る。そのため、main に届く完了があれば、条件を見直す間隔（5 ms）を待たずに
/// 条件を見直す。間隔が効くのは、入力源にならない変化（別スレッドが書く値・ファイル・ソケット）だけ。
/// 成否でテストの流れを分けるとき、`XCTAssertTrue` に自分の文言を添えるときに使う（ほかは `pumpMain(until:)`）。
@discardableResult
public func waitUntil(_ seconds: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool
{
  let deadline = Date().addingTimeInterval(seconds)
  while true {
    if try condition() { return true }
    guard Date() < deadline else { return false }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
  }
}

/// 条件が成り立つまで待ち、成り立たなければ呼び出した行で失敗を記録する。
public func pumpMain(
  until condition: () -> Bool, timeout: TimeInterval = 10,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertTrue(
    waitUntil(timeout, condition), "\(timeout) 秒以内に成立しない: \(message())", file: file, line: line)
}

/// ランループを、待たずに 1 周だけ回す。
///
/// ランループの 1 周の終わりに走る observer を、ちょうど 1 回走らせるためだけに使う。操作の結果が届くのを
/// 待つ目的には使わない（main のキューで届く結果は `nextTurn()` を使い、ほかは条件待ちを使う）。
public func pumpMainOnce() {
  RunLoop.main.run(until: Date())
}

/// main のキューに目印を積み、目印が走るまで待つ。戻ったとき、呼ぶ前に main のキューへ積まれていた仕事は、
/// すべて走り終えている。
///
/// 否定条件の 3 段め（起きてはいけない結果を届けうる仕事が、既に main のキューに積まれている）で使う。
public func nextTurn(file: StaticString = #filePath, line: UInt = #line) {
  var reached = false
  DispatchQueue.main.async { reached = true }
  pumpMain(until: { reached }, "main のキューの目印", file: file, line: line)
}

/// 条件が、渡した秒数のあいだ成り立ち続けるかを、実時間で見張る。破れた時点で false を返す。
///
/// 否定条件の 5 段め（同期的に決まらず、終わりを観測できず、順序を保つ経路にも無く、時計を差し替えられない）
/// だけで使う。見張る秒数は、結果が届くまでの本番の遅延の定数から決める。
public func holds(for seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
  !waitUntil(seconds) { !condition() }
}
