import XCTest

@testable import Orbe

/// 取り込み済み音源の置き場と、参照集合 GC の**純関数部分**（渡された集合の外を消す）。
///
/// 参照集合をどう組むか（どの層まで走るか）と呼び出し順序は `WindowController` 側の契約なので、
/// そちらは `WindowControllerReportAgentTests+Sound` が実経路で押さえる——ここで代役を立てると、
/// production に無い順序をテスト内で再現して「順序は守られている」と誤って安心することになる。
final class CustomSoundStoreTests: OrbeTestCase {

  @discardableResult
  private func place(_ name: String) throws -> URL {
    let url = try XCTUnwrap(CustomSoundStore.url(for: name))
    try Data("wav".utf8).write(to: url)
    return url
  }

  private func names() throws -> Set<String> {
    let dir = try XCTUnwrap(CustomSoundStore.directoryURL())
    let files = try FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil)
    return Set(files.map(\.lastPathComponent))
  }

  /// 隔離ハーネスが置き場を per-test ディレクトリへ張っている（実 state dir を汚さない）。
  func testDirectoryIsIsolated() throws {
    let dir = try XCTUnwrap(CustomSoundStore.directoryURL())
    XCTAssertEqual(dir.lastPathComponent, "sounds")
    // 隔離根の下、ではなく **caseDir 直下**を見る——根の直下は `endCase` の削除に乗らないので、
    // override が外れて fallback（`StateDir.base()/sounds`）へ落ちても気づけなくなる。
    XCTAssertEqual(
      dir.deletingLastPathComponent().path, try XCTUnwrap(TestIsolation.caseDir).path,
      "置き場が per-test ディレクトリの外にある: \(dir.path)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "参照時に作られる")
  }

  /// 取り込みごとに違う名前になる（同名の in-place 上書きが起きない＝再生中バッファと競合しない）。
  func testNewFileNameIsUnique() {
    let names = (0..<8).map { _ in CustomSoundStore.newFileName() }
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertTrue(names.allSatisfy { $0.hasSuffix(".wav") })
  }

  /// ディレクトリを跨ぐ名前は解決しない（手編集された settings.json から外へ触らせない）。
  func testUrlRejectsPathEscapes() {
    for bad in ["", "..", "../evil.wav", "sub/evil.wav"] {
      XCTAssertNil(CustomSoundStore.url(for: bad), bad)
    }
  }

  // MARK: - 参照集合 GC

  /// 参照されているファイルは残り、参照されていないファイルだけが消える。
  func testCollectGarbageRemovesOnlyUnreferencedFiles() throws {
    try place("kept.wav")
    try place("orphan.wav")
    CustomSoundStore.collectGarbage(referenced: ["kept.wav"])
    XCTAssertEqual(try names(), ["kept.wav"])
  }

  /// 参照集合が空なら全部消える（カスタムをやめて案へ戻したときの後始末）。
  func testCollectGarbageWithNoReferencesEmptiesTheDirectory() throws {
    try place("a.wav")
    try place("b.wav")
    CustomSoundStore.collectGarbage(referenced: [])
    XCTAssertTrue(try names().isEmpty)
  }

  /// 前回起動の孤児（手編集・クラッシュ由来）は、次に GC が走ったときにまとめて回収される
  /// ——毎回 `sounds/` 全体を参照集合と突き合わせるので、遅れて走っても取り漏らさない。
  func testStaleOrphansAreReclaimedByTheNextCollection() throws {
    try place("orphan-from-last-launch.wav")
    try place("another-orphan.wav")
    try place("current.wav")
    CustomSoundStore.collectGarbage(referenced: ["current.wav"])
    XCTAssertEqual(try names(), ["current.wav"])
  }
}
