import XCTest

@testable import OrbeSound
@testable import orbe_sound

/// 実バイナリ `orbe-sound` の引数解釈と出口契約（exit 0=成功 / 2=usage エラー / 1=実行エラー）。
/// エラー経路は `usageDie` / `die` が exit するため in-process では測れず、subprocess で駆動する
/// （L4 の流儀。バイナリはテストバンドルの隣 = `.build/.../debug/` から解決する）。
///
/// 壊れると何が起きるか: 解釈されなかった引数が黙って捨てられ、指定と違うレート・音量・音を
/// 聴いて音作りの判断を誤る——エラーは exit 0 の顔で通り過ぎ、人間は成功したと読む。
final class OrbeSoundProcessTests: XCTestCase {

  private struct Output {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  private func run(_ args: [String]) throws -> Output {
    let binary = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("orbe-sound")
    let process = Process()
    process.executableURL = binary
    process.arguments = args
    process.environment = [:]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Output(
      status: process.terminationStatus,
      stdout: String(bytes: stdoutData, encoding: .utf8) ?? "",
      stderr: String(bytes: stderrData, encoding: .utf8) ?? "")
  }

  private func tempPath(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-cli-test-\(UUID().uuidString)\(suffix)")
  }

  // MARK: - ディスパッチと usage（exit 2 / 0）

  /// 引数なしは usage を stdout へ出して exit 2（迷った人に案内は出すが、成功とは区別する）。
  func testNoArgumentsPrintsUsageAndExitsTwo() throws {
    let result = try run([])
    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.stdout.contains("USAGE:"))
  }

  /// `--help` はコマンド位置でだけ効いて exit 0。サブコマンド別 help は無い（`list --help` は exit 2）。
  func testHelpExitsZeroOnlyInTheCommandPosition() throws {
    let help = try run(["--help"])
    XCTAssertEqual(help.status, 0)
    XCTAssertTrue(help.stdout.contains("USAGE:"))
    XCTAssertEqual(try run(["list", "--help"]).status, 2)
  }

  /// 未知コマンドは exit 2 で名指しされる。
  func testUnknownCommandExitsTwo() throws {
    let result = try run(["frobnicate"])
    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.stderr.contains("unknown command"))
  }

  /// `list` はカタログ全案と scratch 全エントリを列挙する（載らない音は制作ループから静かに漏れる）。
  func testListNamesEveryCatalogAndScratchSound() throws {
    let result = try run(["list"])
    XCTAssertEqual(result.status, 0)
    for family in NotificationSound.allCases {
      XCTAssertTrue(result.stdout.contains(family.rawValue), "\(family.rawValue) が載らない")
    }
    for entry in Scratch.entries {
      XCTAssertTrue(result.stdout.contains(entry.name), "\(entry.name) が載らない")
    }
  }

  // MARK: - render / analyze / board の成功経路（exit 0）

  /// render はカタログ・scratch のどちらも WAV を書き、stdout にパスを出す（resolve の 2 経路）。
  func testRenderWritesAWavAndPrintsThePath() throws {
    let catalogOut = tempPath(".wav")
    defer { try? FileManager.default.removeItem(at: catalogOut) }
    let catalog = try run(["render", "glass", "done", "--rate", "8000", "--out", catalogOut.path])
    XCTAssertEqual(catalog.status, 0)
    XCTAssertTrue(catalog.stdout.contains(catalogOut.path))
    XCTAssertEqual(
      String(bytes: try Data(contentsOf: catalogOut).prefix(4), encoding: .utf8), "RIFF")

    guard let scratchName = Scratch.entries.first?.name else {
      throw XCTSkip("scratch が空")
    }
    let scratchOut = tempPath(".wav")
    defer { try? FileManager.default.removeItem(at: scratchOut) }
    let scratch = try run([
      "render", scratchName, "-", "--rate", "8000", "--out", scratchOut.path,
    ])
    XCTAssertEqual(scratch.status, 0, scratch.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: scratchOut.path))
  }

  /// analyze はメトリクス行とスペクトルピークを出す。
  func testAnalyzePrintsTheMetricsRow() throws {
    let result = try run(["analyze", "glass", "done", "--rate", "8000"])
    XCTAssertEqual(result.status, 0)
    for token in ["glass/done", "peak", "rms", "crest", "spectral peaks"] {
      XCTAssertTrue(result.stdout.contains(token), "\(token) が出ない: \(result.stdout)")
    }
  }

  /// analyze --all はカタログ 24 音 + scratch 全エントリで 1 行ずつ出す（欠けた音は整合の目視から漏れる）。
  func testAnalyzeAllListsEverySound() throws {
    let result = try run(["analyze", "--all", "--rate", "8000"])
    XCTAssertEqual(result.status, 0)
    let expected =
      NotificationSound.allCases.count * AgentSoundEvent.allCases.count + Scratch.entries.count
    XCTAssertEqual(result.stdout.split(separator: "\n").count, expected)
  }

  /// board は引数を解釈して index.html のパスを出す（生成物の中身は BoardTests が持つ）。
  func testBoardParsesArgumentsAndPrintsTheIndexPath() throws {
    let dir = tempPath("")
    defer { try? FileManager.default.removeItem(at: dir) }
    let result = try run(["board", "--out", dir.path, "--rate", "8000"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("index.html"))
  }

  // MARK: - usage エラー（exit 2。黙って捨てない契約）

  /// 未知の音名・イベントトークンの取り違えは exit 2 で名指しされる（resolve の 3 分岐の失敗側）。
  func testSoundResolutionErrorsExitTwo() throws {
    let unknown = try run(["render", "nosuch", "done"])
    XCTAssertEqual(unknown.status, 2)
    XCTAssertTrue(unknown.stderr.contains("unknown sound"))

    let catalogNeedsEvent = try run(["analyze", "glass", "-", "--rate", "8000"])
    XCTAssertEqual(catalogNeedsEvent.status, 2)
    XCTAssertTrue(catalogNeedsEvent.stderr.contains("needs <done|waiting>"))

    guard let scratchName = Scratch.entries.first?.name else { throw XCTSkip("scratch が空") }
    let scratchHasNoEvents = try run(["analyze", scratchName, "done"])
    XCTAssertEqual(scratchHasNoEvents.status, 2)
    XCTAssertTrue(scratchHasNoEvents.stderr.contains("has no events"))
  }

  /// 席に座れなかったトークンは黙って捨てず exit 2（捨てると指定と違う音を聴いて判断を誤る）。
  func testLeftoverTokensAreRejected() throws {
    for args in [
      ["render", "glass", "done", "extra"],
      ["list", "--verbose"],
      ["analyze", "glass", "done", "--nope", "1"],
      ["board", "extra"],
    ] {
      let result = try run(args)
      XCTAssertEqual(result.status, 2, "\(args)")
      XCTAssertTrue(
        result.stderr.contains("unknown option") || result.stderr.contains("unexpected argument"),
        "\(args): \(result.stderr)")
    }
  }

  /// 下限未満のレート・範囲外の音量は exit 2・"invalid"（単体経路と board の検証）。
  func testOutOfRangeRateAndVolumeExitTwo() throws {
    for args in [
      ["analyze", "glass", "done", "--rate", "4000"],
      ["analyze", "glass", "done", "--volume", "0"],
      ["render", "glass", "done", "--volume", "101"],
      ["board", "--rate", "4000"],
    ] {
      let result = try run(args)
      XCTAssertEqual(result.status, 2, "\(args)")
      XCTAssertTrue(result.stderr.contains("invalid"), "\(args): \(result.stderr)")
    }
  }

  /// `analyze --all` も単体経路と同じ検証を通る——読めない値も範囲外の値も exit 2。
  /// 検証が抜けると、指定と違うレートの表やクリップした音量の表が exit 0 の顔で出て、
  /// ラウドネス整合の判断材料そのものが壊れる。
  func testAnalyzeAllValidatesRateAndVolume() throws {
    for args in [
      ["analyze", "--all", "--rate", "abc"],
      ["analyze", "--all", "--rate", "4000"],
      ["analyze", "--all", "--volume", "999"],
    ] {
      let result = try run(args)
      XCTAssertEqual(result.status, 2, "\(args)")
      XCTAssertTrue(result.stderr.contains("invalid"), "\(args): \(result.stderr)")
    }
  }

  /// 非有限・変換域外のレートは usage エラーで弾く——0/1/2 の契約の外（シグナル死）へ落とさない。
  /// 上限 768000（8×96 kHz）は「Double→Int 変換の域外の値が合成層へ届かない」ことの入口の守り。
  func testAbsurdRatesAreUsageErrorsNotCrashes() throws {
    for args in [
      ["analyze", "glass", "done", "--rate", "inf"],
      ["render", "glass", "done", "--rate", "1e300"],
      ["board", "--rate", "inf"],
      ["analyze", "--all", "--rate", "1e300"],
    ] {
      let result = try run(args)
      XCTAssertEqual(result.status, 2, "\(args): 契約外の出口へ落ちている")
      XCTAssertTrue(result.stderr.contains("invalid rate"), "\(args): \(result.stderr)")
    }
  }

  // MARK: - 実行エラー（exit 1）

  /// 書けない出力先は usage でなく実行エラー（exit 1）に落ちる。
  func testUnwritableOutputPathExitsOne() throws {
    let result = try run([
      "render", "glass", "done", "--rate", "8000",
      "--out", "/nonexistent-dir-orbe-sound-test/x.wav",
    ])
    XCTAssertEqual(result.status, 1)
    XCTAssertTrue(result.stderr.contains("cannot write"))
  }
}
