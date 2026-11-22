import Foundation
import XCTest

// テストが条件の成立や main の進みを待つ処理の実装。`sleepUntil` のほかは、テストが走る main のスレッドで呼ぶ。
// 否定条件の確かめ方の順（docs/testing/test-architecture.md の「待ち」）との対応は、関数ごとに書く。

/// 条件が成り立つまでランループを回して待ち、期限までに成り立ったかを返す。
///
/// 先に条件を見るので、既に成り立っていればランループを回さない。ランループは、main のキューの仕事などの
/// 入力源を 1 つ処理すると戻る。そのため、main に届く完了があれば、条件を見直す間隔（5 ms）を待たずに
/// 条件を見直す。間隔が効くのは、入力源にならない変化（main のタイマー・別スレッドが書く値・ファイル・ソケット）だけ。
/// 成否でテストの流れを分けるとき、`XCTAssertTrue` に自分の文言を添えるとき、待った後の確かめを続く検証に
/// 任せるときに使う（ほかは `pumpMain(until:)`）。
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

/// ランループを回さずに、条件が成り立つまでこのスレッドを止めて待ち、期限までに成り立ったかを返す。
///
/// 条件は 1 ms ごとに見直す。main に届く出来事を待つなら `waitUntil` を使う。こちらは、main を塞いだまま待つ必要が
/// 在るとき（main が進まないことが前提のテスト）と、main でないスレッドから待つときに使う。どのスレッドからも呼べる。
@discardableResult
public func sleepUntil(_ seconds: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while true {
    if try condition() { return true }
    guard Date() < deadline else { return false }
    Thread.sleep(forTimeInterval: 0.001)
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
/// main のキューに積まれた仕事の結果を、その仕事が走り終えた時点で確かめるときに使う。起きるはずの結果を
/// 確かめるときにも使う。否定条件のうち、起きてはいけない結果を届けうる仕事が既に main のキューに積まれている
/// ものにも使う。
public func nextTurn(file: StaticString = #filePath, line: UInt = #line) {
  var reached = false
  DispatchQueue.main.async { reached = true }
  pumpMain(until: { reached }, "main のキューの目印", file: file, line: line)
}

/// 条件が、渡した秒数のあいだ成り立ち続けるかを、実時間で見張る。破れた時点で false を返す。
///
/// 否定条件のうち、同期的に決まらず、終わりを観測できず、順序を保つ経路にも無く、時計を差し替えられないもの
/// にだけ使う。見張る秒数は、本番に、結果が届くまでの遅延の定数が在れば、そこから決める。
public func holds(for seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
  !waitUntil(seconds) { !condition() }
}
