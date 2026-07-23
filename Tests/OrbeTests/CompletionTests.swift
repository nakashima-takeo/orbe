import XCTest

@testable import Orbe

/// CompletionLegacyCleanup（旧 managed block の除去）と accept 系純ロジック
/// （applyChoice・insertText・isRedundantSoleChoice）を検証する。ユーザ資産編集の安全性
/// （block 外不可侵・除去）とトークン置換の契約を担保する。
/// shim（ZDOTDIR interposition）の契約は CompletionShimTests が持つ。
/// エンジン（prebuilt JS バンドル）の契約は CompletionEngineTests が持つ。
final class CompletionTests: XCTestCase {
  private var dir: URL!
  private var zshrc: URL!

  override func setUpWithError() throws {
    dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("CompletionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    zshrc = dir.appendingPathComponent(".zshrc")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func read() -> String { (try? String(contentsOf: zshrc, encoding: .utf8)) ?? "" }

  // MARK: - CompletionLegacyCleanup

  /// 旧 install が書いていた形（前置空行 1 つ＋マーカー対）を再現する。
  private let legacyBlock = """

    # >>> orbe completion >>>
    [[ -n $LEGACY_GUARD ]] && source "$LEGACY_GUARD"
    # <<< orbe completion <<<

    """

  func testRemoveManagedBlockKeepsRest() {
    try? Data(("export FOO=1\nexport BAR=2\n" + legacyBlock).utf8).write(to: zshrc)
    CompletionLegacyCleanup.removeManagedBlock(at: zshrc)
    let text = read()
    XCTAssertFalse(text.contains("orbe completion"), "マーカー間が除去される")
    XCTAssertTrue(text.contains("export FOO=1"))
    XCTAssertTrue(text.contains("export BAR=2"))
  }

  func testRemoveManagedBlockTakesPrecedingBlankLine() {
    try? Data(("export FOO=1\n" + legacyBlock).utf8).write(to: zshrc)
    CompletionLegacyCleanup.removeManagedBlock(at: zshrc)
    XCTAssertEqual(read(), "export FOO=1\n", "旧 install が入れた前置空行も 1 つ巻き込む")
  }

  func testRemoveManagedBlockNoOpWhenAbsent() {
    let original = "export FOO=1\n"
    try? Data(original.utf8).write(to: zshrc)
    CompletionLegacyCleanup.removeManagedBlock(at: zshrc)
    XCTAssertEqual(read(), original, "block 外は一切触らない")
  }

  // MARK: - accept（現在トークン置換の純ロジック）

  func testApplyReplacesCurrentToken() {
    // "git st" の現在トークン st（4..<6）を status へ置換し、素の候補なので末尾へ空白を補う。
    let r = SurfaceView.applyChoice(
      buffer: "git st", replaceStart: 4, replaceEnd: 6, insert: "status", appendSpace: true)
    XCTAssertEqual(r.buffer, "git status ")
    XCTAssertEqual(r.cursor, 11)
  }

  func testApplyUsesScalarOffsetsWithCombiningMarks() {
    // "café x"（café は NFD: e + U+0301）はコードポイント 7・書記素 6。zsh/engine は scalar 単位で
    // 末尾トークン "x"（replaceStart=6, replaceEnd=7）を渡す。書記素配列だと end が 6 に潰れて
    // "x" を置換できず "café xyy" になる。scalar 単位なら正しく "café yy"・cursor=8。
    let r = SurfaceView.applyChoice(
      buffer: "cafe\u{0301} x", replaceStart: 6, replaceEnd: 7, insert: "yy", appendSpace: false)
    XCTAssertEqual(r.buffer, "cafe\u{0301} yy")
    XCTAssertEqual(r.cursor, 8)
  }

  func testApplyKeepsSuffixAfterCursor() {
    // カーソルは "git co" 直後（範囲 4..<6）。後続 " -m x" が既に空白始まりなので空白は足さない。
    let r = SurfaceView.applyChoice(
      buffer: "git co -m x", replaceStart: 4, replaceEnd: 6, insert: "commit", appendSpace: true)
    XCTAssertEqual(r.buffer, "git commit -m x")
    XCTAssertEqual(r.cursor, 10)
  }

  func testApplyUsesInsertValueDistinctFromDisplay() {
    // insertValue を持つ候補（--flag= 等）は verbatim 挿入で空白を足さない（appendSpace: false）。
    let r = SurfaceView.applyChoice(
      buffer: "git --co", replaceStart: 4, replaceEnd: 8, insert: "--color=", appendSpace: false)
    XCTAssertEqual(r.buffer, "git --color=")
    XCTAssertEqual(r.cursor, 12)
  }

  func testApplyAppendsSpaceForBareName() {
    // 素の候補（insertValue 無し）は末尾へ空白を1つ補い、カーソルを空白後へ置く。
    let r = SurfaceView.applyChoice(
      buffer: "gi", replaceStart: 0, replaceEnd: 2, insert: "git", appendSpace: true)
    XCTAssertEqual(r.buffer, "git ")
    XCTAssertEqual(r.cursor, 4)
  }

  func testApplyGuardsDoubleSpaceWhenFollowedBySpace() {
    // 行途中確定で後続が空白なら、appendSpace でも二重空白にしない（zsh AUTO_PARAM_KEYS 同型）。
    let r = SurfaceView.applyChoice(
      buffer: "gi commit", replaceStart: 0, replaceEnd: 2, insert: "git", appendSpace: true)
    XCTAssertEqual(r.buffer, "git commit")
    XCTAssertEqual(r.cursor, 3)
  }

  func testApplyFolderInsertValueNoSpace() {
    // folder は engine が末尾 / 付き insertValue を焼く＝appendSpace: false。パス継続を壊さない。
    let r = SurfaceView.applyChoice(
      buffer: "cd sr", replaceStart: 3, replaceEnd: 5, insert: "src/", appendSpace: false)
    XCTAssertEqual(r.buffer, "cd src/")
    XCTAssertEqual(r.cursor, 7)
  }

  func testApplyFileInsertValueNoSpace() {
    // file も insertValue を持つ（appendSpace: false）＝空白を足さない（inshellisense 忠実）。
    let r = SurfaceView.applyChoice(
      buffer: "cat RE", replaceStart: 4, replaceEnd: 6, insert: "README.md", appendSpace: false)
    XCTAssertEqual(r.buffer, "cat README.md")
    XCTAssertEqual(r.cursor, 13)
  }

  // MARK: - insertText（Enter 確定で末尾 / を落とす純ロジック）

  func testInsertTextDropsTrailingSlashOnEnter() {
    // Enter（advance=false）は folder の末尾 / を落とし `src` の形で確定する。
    XCTAssertEqual(SurfaceView.insertText("src/", advance: false), "src")
  }

  func testInsertTextKeepsTrailingSlashOnTab() {
    // Tab（advance=true）は次階層へ潜れるよう末尾 / を保つ。
    XCTAssertEqual(SurfaceView.insertText("src/", advance: true), "src/")
  }

  func testInsertTextLeavesNonSlashUnchanged() {
    // 末尾 / を帯びない候補（file 等）は Enter でも無変化。
    XCTAssertEqual(SurfaceView.insertText("README.md", advance: false), "README.md")
  }

  func testInsertTextKeepsBareRootSlash() {
    // 単独 /（ルート）は落とさず空文字化しない（安全弁）。
    XCTAssertEqual(SurfaceView.insertText("/", advance: false), "/")
  }

  // MARK: - isRedundantSoleChoice（一択かつ完全一致で popup を閉じる純ロジック）

  private func choice(_ value: String, insertValue: String? = nil, type: String? = nil)
    -> CompletionChoice
  {
    CompletionChoice(value: value, description: "", insertValue: insertValue, type: type)
  }

  func testRedundantSoleChoiceExactMatch() {
    // 一択 value=="pull" × token=="pull" → 冗長（打ち切り済み）なので閉じる。
    XCTAssertTrue(SurfaceView.isRedundantSoleChoice([choice("pull")], tokenText: "pull"))
  }

  func testRedundantSoleChoicePartialMatchStaysOpen() {
    // 部分一致（token=="pul"）は途中なので閉じない。
    XCTAssertFalse(SurfaceView.isRedundantSoleChoice([choice("pull")], tokenText: "pul"))
  }

  func testRedundantSoleChoiceMultipleStaysOpen() {
    // 複数候補はいずれか完全一致でも閉じない（選ぶ余地が残る）。
    XCTAssertFalse(
      SurfaceView.isRedundantSoleChoice([choice("pull"), choice("push")], tokenText: "pull"))
  }

  func testRedundantSoleChoiceFolderUsesInsertText() {
    // folder は insertValue=="src/" を insertText で "src" に均してから比較 → token=="src" で閉じる。
    XCTAssertTrue(
      SurfaceView.isRedundantSoleChoice(
        [choice("src", insertValue: "src/", type: "folder")], tokenText: "src"))
  }

  func testRedundantSoleChoiceInsertValueExpansionStaysOpen() {
    // 一択でも insertValue が value と別の展開形（実挿入が no-op でない）なら閉じない。
    // 例: value=="-ldflags"==token でも Enter は "-ldflags=" を挿入するので popup を残す。
    XCTAssertFalse(
      SurfaceView.isRedundantSoleChoice(
        [choice("-ldflags", insertValue: "-ldflags=")], tokenText: "-ldflags"))
  }

  func testRedundantSoleChoiceIsCaseSensitive() {
    // value は spec の正規名。大小違いの入力は不一致＝閉じない（engine の大小無視とは別契約・安全側）。
    XCTAssertFalse(SurfaceView.isRedundantSoleChoice([choice("pull")], tokenText: "PULL"))
  }

}
