import UniformTypeIdentifiers
import XCTest

@testable import Orbe

/// ローカルファイルを内容の家族に振り分けた開き先。テキストはエディタ、画像・PDF・AV は型の既定アプリ、
/// フォルダは Finder に渡す。転送ファイルとアプリ・実行形式は開かず、どの家族でもないものは確認に回す。
extension UntrustedLinkTests {
  // MARK: - テキスト

  /// macOS が型を知らない拡張子でも、中身が UTF-8 テキストならエディタで開く。
  func testUnknownExtensionWithTextContentOpensInEditor() throws {
    let source = try makeFile("main.zig", Data("const std = @import(\"std\");\n".utf8))
    XCTAssertEqual(fileDecision(source), .allow(.text(canonical(source))))
  }

  /// 型を知らない拡張子で中身がテキストでなければ（NUL 入り・UTF-8 として壊れている）、開く前に確認を求める。
  func testUnknownExtensionWithBinaryContentRequiresConfirmation() throws {
    let withNUL = try makeFile("main.zig", Self.binaryContent)
    let brokenUTF8 = try makeFile("lib.zig", Data([0x61, 0x62, 0xE3, 0x81]))
    XCTAssertEqual(fileDecision(withNUL), .confirm(canonical(withNUL)))
    XCTAssertEqual(fileDecision(brokenUTF8), .confirm(canonical(brokenUTF8)))
  }

  /// 大きなテキストは、中身の判定で読む範囲の切れ目が多バイト文字の途中に当たってもテキストのまま。
  func testLargeTextCutInsideMultibyteCharacterOpensInEditor() throws {
    let text = String(repeating: "a", count: 8 * 1024 - 1) + String(repeating: "あ", count: 100)
    let log = try makeFile("build.zig", Data(text.utf8))
    XCTAssertEqual(fileDecision(log), .allow(.text(canonical(log))))
  }

  /// 実行ビット付きのスクリプト・Terminal で実行される拡張子・IDLE に渡る拡張子も、エディタで開く（実行しない）。
  func testScriptsOpenInEditorRegardlessOfExecutableBit() throws {
    for name in ["tool.txt", "setup.sh", "run.command", "app.py"] {
      let script = try makeFile(name, Data("#!/bin/sh\necho hi\n".utf8), executable: true)
      XCTAssertEqual(fileDecision(script), .allow(.text(canonical(script))), name)
    }
  }

  /// 拡張子の無い実行ビット付きファイルでも、中身がテキスト（シェルスクリプト等）ならエディタで開く。
  func testExtensionlessExecutableWithTextContentOpensInEditor() throws {
    let script = try makeFile("tool", Data("#!/bin/sh\necho hi\n".utf8), executable: true)
    XCTAssertEqual(fileDecision(script), .allow(.text(canonical(script))))
  }

  /// テキストと解される型を専用アプリ（JavaLauncher・ProfileHelper）が引き受ける拡張子も、エディタで開く。
  func testTextTypesClaimedByLauncherAppsOpenInEditor() throws {
    for name in ["app.jnlp", "device.configprofile"] {
      let file = try makeFile(name, Data("<?xml version=\"1.0\"?>\n<root/>\n".utf8))
      XCTAssertEqual(fileDecision(file), .allow(.text(canonical(file))), name)
    }
  }

  // MARK: - 画像・PDF・音声/動画

  /// 画像・PDF・音声/動画は、ファイルの型で引いた既定アプリで開く。
  func testMediaFilesOpenWithDefaultAppForTheirType() throws {
    for (name, family) in [
      ("a.png", UTType.image), ("a.pdf", .pdf), ("a.mp4", .audiovisualContent),
    ] {
      let file = try makeFile(name, Self.binaryContent)
      guard case .allow(.typed(let url, let type)) = fileDecision(file) else {
        XCTFail("\(name) が型の既定アプリで開かれない: \(fileDecision(file))")
        continue
      }
      XCTAssertEqual(url, canonical(file), name)
      XCTAssertTrue(type.conforms(to: family), "\(name) の型 \(type.identifier)")
    }
  }

  // MARK: - フォルダ

  /// package でないディレクトリは Finder で見せる。
  func testPlainDirectoryOpensInFinder() throws {
    let folder = try makeDirectory("folder")
    XCTAssertEqual(fileDecision(folder), .allow(.folder(canonical(folder))))
  }

  /// package のディレクトリ（プロジェクト・環境設定パネル）は、開く前に確認を求める。
  func testPackageDirectoryRequiresConfirmation() throws {
    for name in ["App.xcodeproj", "Pane.prefPane"] {
      let package = try makeDirectory(name)
      XCTAssertEqual(fileDecision(package), .confirm(canonical(package)), name)
    }
  }

  // MARK: - どの家族でもないファイル

  /// アーカイブ・ディスクイメージ・インストーラ・Terminal 設定・ショートカットは、開く前に確認を求める。
  func testFilesOutsideEveryFamilyRequireConfirmation() throws {
    for name in ["a.zip", "a.dmg", "a.pkg", "a.terminal", "a.shortcut"] {
      let file = try makeFile(name, Self.binaryContent)
      XCTAssertEqual(fileDecision(file), .confirm(canonical(file)), name)
    }
  }

  // MARK: - 開かないファイル

  /// 別の場所を指す転送ファイルは、中身がテキストでも開かない。
  func testForwardingFilesAreBlocked() throws {
    for name in ["a.webloc", "a.inetloc", "a.fileloc", "a.afploc", "a.url"] {
      let file = try makeFile(name)
      XCTAssertEqual(fileDecision(file), .block(.unsafeFile), name)
    }
  }

  /// アプリバンドルと、中身がテキストでない実行ファイルは開かない。
  func testApplicationsAndBinaryExecutablesAreBlocked() throws {
    let app = try makeDirectory("Fake.app")
    let binary = try makeFile("tool", Self.binaryContent, executable: true)
    XCTAssertEqual(fileDecision(app), .block(.unsafeFile))
    XCTAssertEqual(fileDecision(binary), .block(.unsafeFile))
  }

  /// 存在しないファイル（開けば別の対象を指す拡張子でも）と、通常ファイルでもディレクトリでもない実体は開かない。
  func testMissingOrSpecialFileIsBlocked() {
    XCTAssertEqual(
      fileDecision(dir.appendingPathComponent("absent.fileloc")), .block(.inaccessibleFile))
    XCTAssertEqual(decision("file:///dev/null"), .block(.inaccessibleFile))
  }

  // MARK: - 綴りではなく実体で判定する

  /// symlink や `..` の綴りは畳まれ、実体の家族と実体の場所で開く。
  func testSymlinkAndDotDotAreResolvedBeforeOpening() throws {
    let file = try makeFile("notes.txt")
    let folder = try makeDirectory("folder")
    let link = dir.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    XCTAssertEqual(fileDecision(link), .allow(.text(canonical(file))))
    XCTAssertEqual(
      decision("file://\(folder.path)/../notes.txt"), .allow(.text(canonical(file))))
  }

  /// 無害そうな名前の symlink や `..` の綴りの裏にあるバイナリ実行ファイルも、実体で判定して開かない。
  func testBinaryExecutableBehindHarmlessSpellingIsBlocked() throws {
    try makeFile("tool", Self.binaryContent, executable: true)
    let disguise = dir.appendingPathComponent("readme.txt")
    try FileManager.default.createSymbolicLink(
      at: disguise, withDestinationURL: dir.appendingPathComponent("tool"))
    let folder = try makeDirectory("folder")

    XCTAssertEqual(fileDecision(disguise), .block(.unsafeFile))
    XCTAssertEqual(decision("file://\(folder.path)/../tool"), .block(.unsafeFile))
  }
}
