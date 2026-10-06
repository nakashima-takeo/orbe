import Foundation
import XCTest

/// テストの作業ディレクトリとテストの境界。全テストターゲットで、テストが使う一時ディレクトリの唯一の配り手。
///
/// ```
/// root      $TMPDIR/orbe-t-<8桁hex>   … 初回アクセスで作り、バンドル終了で消す
///   c<連番>/  caseDir                 … テストの中で初めて触れた時に作り、そのテストの終了で消す
/// ```
///
/// 消す責任はここが丸ごと持つ。テストの成否を問わず、中を書き込み禁止にしていても権限を戻して消す。
/// プロセスがクラッシュ・SIGKILL で死んだ場合は、プロセス外の見張り（`/bin/sh`）が消す。
public enum TestScratch {
  /// プロセスの隔離根。テスト 1 件より長い寿命で置くものだけをここへ直接置く（テスト終了では消えない）。
  public static var root: URL { ignite() }

  /// 実行中のテスト 1 件の作業ディレクトリ。
  public static var caseDir: URL {
    let root = ignite()
    guard insideCase else {
      preconditionFailure(
        "TestScratch.caseDir をテストの外（テスト終了後のクロージャ・class setUp など）で使った。"
          + "テストをまたいで使うものは TestScratch.root の下に置く")
    }
    if let current { return current }
    dispensed += 1
    let dir = root.appendingPathComponent("c\(dispensed)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    current = dir
    return dir
  }

  /// 直前に配った作業ディレクトリ。配り直しと後始末を測るためだけに持つ。
  public private(set) nonisolated(unsafe) static var previousCaseDir: URL?

  /// テストの境界で呼ぶ口を足す。`begin` はテスト開始時、`end` は作業ディレクトリを消す前に呼ぶ。
  ///
  /// 境界は XCTest の observer が受けるので、`begin` はインスタンスの `setUp()` より前に必ず走る
  /// （`super.setUp()` の呼び忘れで無言に外れる経路が無い）。
  public static func addCaseHooks(begin: @escaping () -> Void, end: @escaping () -> Void) {
    _ = ignite()
    beginHooks.append(begin)
    endHooks.append(end)
  }

  private nonisolated(unsafe) static var ignitedRoot: URL?
  private nonisolated(unsafe) static var insideCase = false
  private nonisolated(unsafe) static var current: URL?
  private nonisolated(unsafe) static var dispensed = 0
  private nonisolated(unsafe) static var beginHooks: [() -> Void] = []
  private nonisolated(unsafe) static var endHooks: [() -> Void] = []
  private nonisolated(unsafe) static var observer: Observer?
  private nonisolated(unsafe) static var watchdogPipe: Pipe?

  /// 点火はテストの中でも起きうる（開始の通知より後に点火したテストの境界は、通知で知れない）ので、点火時は
  /// テストの中とみなす。テストの外（class setUp 等）で配ってしまった分は、次の `begin()` が落とす。
  private static func ignite() -> URL {
    if let ignitedRoot { return ignitedRoot }
    // AF_UNIX の `sun_path`（104 バイト）へ置くソケットのため、UUID 全長ではなく 8 桁の hex に切る。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(String(format: "orbe-t-%08x", UInt32.random(in: 0...UInt32.max)))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    ignitedRoot = dir
    insideCase = true
    startWatchdog(removing: dir)
    let obs = Observer()
    observer = obs
    XCTestObservationCenter.shared.addTestObserver(obs)
    return dir
  }

  /// 書き端をこのプロセスが寿命いっぱい握り、死ねばカーネルが閉じる。見張りはその EOF で根を消して終わる。
  private static func startWatchdog(removing dir: URL) {
    let pipe = Pipe()
    // 子（見張り自身・libghostty のシェル・git・CLI）が書き端を継ぐと、このプロセスが死んでも EOF が来ない。
    _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", #"read _; chmod -R u+rwx "$0" 2>/dev/null; rm -rf "$0""#, dir.path]
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      preconditionFailure("テストの作業ディレクトリの見張りを起こせない: \(error)")
    }
    try? pipe.fileHandleForReading.close()
    watchdogPipe = pipe
  }

  fileprivate static func begin() {
    precondition(
      current == nil,
      "テストの開始前に TestScratch.caseDir が配られていた（class setUp・static 初期化などテストの外で触れた）。"
        + "テストをまたいで使うものは TestScratch.root の下に置く")
    insideCase = true
    for hook in beginHooks { hook() }
  }

  fileprivate static func end() {
    for hook in endHooks { hook() }
    if let current {
      removeForcibly(current)
      previousCaseDir = current
    }
    current = nil
    insideCase = false
  }

  fileprivate static func finishBundle() {
    if let ignitedRoot { removeForcibly(ignitedRoot) }
  }

  private static func removeForcibly(_ url: URL) {
    if (try? FileManager.default.removeItem(at: url)) != nil { return }
    restoreWritePermission(url)
    try? FileManager.default.removeItem(at: url)
  }

  private static func restoreWritePermission(_ url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
    chmod(url.path, (info.st_mode & 0o7777) | S_IRWXU)
    let children =
      (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    for child in children { restoreWritePermission(child) }
  }

  private final class Observer: NSObject, XCTestObservation {
    func testCaseWillStart(_ testCase: XCTestCase) { TestScratch.begin() }
    func testCaseDidFinish(_ testCase: XCTestCase) { TestScratch.end() }
    func testBundleDidFinish(_ testBundle: Bundle) { TestScratch.finishBundle() }
  }
}
