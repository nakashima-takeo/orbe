import XCTest

@testable import Orbe

/// worktree 識別色——キーから色番号を出す規則と、テーマごとの 48 色表が生成スクリプトの出力と一致すること。
///
/// 壊れると何が起きるか。番号の符号化が見本（orbe_design `theme.ts`）とずれると、デザインで
/// 確認した worktree と実装の色が食い違う。basename 以外を混ぜると同じリポジトリの clone が
/// 置き場所ごとに別色になる。NFC 正規化を落とすと、Finder で作った日本語名（NFD）と
/// シェルで打った名前（NFC）で色が変わる。表がスクリプトの出力からずれると、手編集された色が
/// 再生成で黙って消える。
final class WorktreeColorTests: OrbeTestCase {

  // MARK: - 色番号

  /// 番号は basename の FNV-1a（32bit・UTF-8）を 48 で割った余り。既知ベクトルで符号化を固定する。
  func testIndexIsFnv1aOfBasenameModuloPaletteSize() {
    XCTAssertEqual(WorktreePalette.count, 48, "表は 48 色")
    XCTAssertEqual(WorktreePalette.light.count, WorktreePalette.count)
    XCTAssertEqual(WorktreeColor.index(forKey: "/w/a"), 28, "FNV-1a(\"a\") = 0xe40c292c → mod 48")
    XCTAssertEqual(
      WorktreeColor.index(forKey: "/w/foobar"), 40, "FNV-1a(\"foobar\") = 0xbf9cf968 → mod 48")
  }

  /// 置き場所（親ディレクトリ）は関与しない——basename だけで決まる。
  func testIndexDependsOnlyOnBasename() {
    XCTAssertEqual(
      WorktreeColor.index(forKey: "/Users/x/github/storefront"),
      WorktreeColor.index(forKey: "/private/tmp/clones/storefront"))
    XCTAssertEqual(WorktreeColor.index(forKey: "/Users/x/github/storefront"), 25)
  }

  /// NFD（Finder 由来）と NFC（シェル由来）の同じ名前は同じ色。
  func testIndexNormalizesToNFC() {
    let nfc = "/w/caf\u{E9}"
    let nfd = "/w/cafe\u{301}"
    XCTAssertEqual(WorktreeColor.index(forKey: nfd), WorktreeColor.index(forKey: nfc))
    XCTAssertEqual(WorktreeColor.index(forKey: nfc), 25, "NFC の UTF-8 で符号化")
  }

  /// どちらのテーマの表も色は互いに異なる（色相ステップや色数を変えても重複が黙って入らない番人）。
  func testPaletteColorsAreDistinct() {
    XCTAssertEqual(Set(WorktreePalette.dark).count, WorktreePalette.count)
    XCTAssertEqual(Set(WorktreePalette.light).count, WorktreePalette.count)
  }

  // MARK: - 生成物の drift

  /// コミット済み `WorktreePalette.swift` は `scripts/gen-worktree-palette.py` の出力と byte 一致する。
  func testCommittedPaletteMatchesGeneratorOutput() throws {
    let root = repoRoot()
    let script = root.appendingPathComponent("scripts/gen-worktree-palette.py")
    let committed = try String(
      contentsOf: root.appendingPathComponent("Sources/Orbe/DesignSystem/WorktreePalette.swift"),
      encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3", "-B", "-c",
      """
      import importlib.util, sys
      spec = importlib.util.spec_from_file_location("gen", sys.argv[1])
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      sys.stdout.write(mod.generate())
      """,
      script.path,
    ]
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let rendered = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0, "生成スクリプトが走る")
    XCTAssertEqual(
      rendered, committed,
      "WorktreePalette.swift が生成物と不一致。`python3 scripts/gen-worktree-palette.py` で再生成してコミットせよ")
  }

  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }
}
