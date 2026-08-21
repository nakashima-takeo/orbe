import XCTest

@testable import Orbe

/// 取り込み済み音源の置き場と、参照集合 GC。
///
/// GC の呼び出し**順序**（新ファイルを書く → 設定値を差し替える → GC）がこの機構の唯一の危うい点なので、
/// 「順序どおりなら新しいファイルは生き残る」「逆順なら消えうる」を明示的に押さえる。
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
    XCTAssertTrue(
      dir.path.hasPrefix(TestIsolation.root.path), "置き場が隔離根の外にある: \(dir.path)")
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

  /// 「新ファイルを書く → 設定値を差し替える → GC」の順なら、書いたばかりのファイルは生き残り、
  /// 参照されなくなった旧ファイルだけが消える。
  func testWriteThenAssignThenCollectKeepsTheNewFile() throws {
    try place("old.wav")
    var layer = SettingsLayer()
    layer[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "old.wav", name: "old.mp3", duration: 1)

    try place("new.wav")  // 1. 書く
    layer[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "new.wav", name: "new.mp3", duration: 2)  // 2. 値を差し替える
    CustomSoundStore.collectGarbage(  // 3. GC
      referenced: Set([layer[SettingKeys.notificationSoundCustomDone]?.file].compactMap { $0 }))
    XCTAssertEqual(try names(), ["new.wav"])
  }

  /// 逆順（値を差し替える前に GC）だと、書いたばかりの未参照ファイルを消してしまう
  /// ——この危うさがあるから順序が契約になっている、ということをテストでも残す。
  func testCollectingBeforeAssigningWouldDropTheNewFile() throws {
    var layer = SettingsLayer()
    layer[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "old.wav", name: "old.mp3", duration: 1)
    try place("old.wav")
    try place("new.wav")
    CustomSoundStore.collectGarbage(
      referenced: Set([layer[SettingKeys.notificationSoundCustomDone]?.file].compactMap { $0 }))
    XCTAssertFalse(try names().contains("new.wav"))
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
