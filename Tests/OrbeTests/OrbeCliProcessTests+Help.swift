import Foundation
import XCTest

@testable import Orbe

/// `orb --help` が**写している語彙**を、写し元と突き合わせて固定する。
///
/// help は socket 不達でも出す必要があるため、control に問い合わせて組むことができない。そのため
/// key 名・設定 key・`--workspace` の受ける値は CLI 側に写しが置かれており、写しは黙ってドリフト
/// する——実際に `config --help` から 3 key が消え、`pane list` / `tab new` の `--workspace` から
/// `current` が消えたまま出荷された。
///
/// 壊れると何が起きるか: 受け付ける側は減らないので、終了コードにも出力にも現れない。減るのは
/// **help を読んで組み立てる利用者と AI にとっての語彙**だけで、打てば通る機能が「無いもの」になる。
/// どれもサーバ不要で出る経路なので、ここは `WindowController` を立てずに測る。
extension OrbeCliProcessTests {
  /// `orb pane --help` の `KEYS:` は control の `ControlKey.specialKeycodes` と同じ集合。
  ///
  /// 弾くのは control（`ControlKey.parse` が -32602）だが、help は socket 不達でも出す必要が
  /// あるため CLI に名前を写している。
  func testPaneHelpListsEveryKeyName() throws {
    let outcome = ControlProcess.orbWithoutServer(["pane", "--help"])
    XCTAssertEqual(outcome.status, 0, "pane --help は socket 不達でも exit 0: \(outcome.stderr)")
    let line = try XCTUnwrap(
      outcome.stdout.split(separator: "\n").first { $0.hasPrefix("KEYS: ") },
      "pane --help に KEYS: 行が無い: \(outcome.stdout)")
    let listed = line.dropFirst("KEYS: ".count).split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertEqual(
      Set(listed), Set(ControlKey.specialKeycodes.keys),
      "pane --help の KEYS が ControlKey と食い違っている")
  }

  /// `orb config --help` の `KEYS:` は `SettingsRegistry.all` と同じ集合。
  ///
  /// usage は socket 不達でも出す必要があるため `config_list` からは引けず、CLI 側に key を写している。
  /// その写しはこれまで散文の申し送りだけで守られており、実際にドリフトして 3 key（`tab-title-font-family`
  /// `emoji-font` `worktree-dir`）が欠けたまま出荷された。
  ///
  /// registry に足した設定が help から漏れると「打てば通るが help には無い」key になる。
  /// `config set` は `config_list` を SSOT に検証するので通ってしまい、CLI からも help を読む
  /// 自動化からも発見できない。
  func testConfigHelpListsEveryRegistryKey() throws {
    let outcome = ControlProcess.orbWithoutServer(["config", "--help"])
    XCTAssertEqual(outcome.status, 0, "config --help は socket 不達でも exit 0: \(outcome.stderr)")
    let line = try XCTUnwrap(
      outcome.stdout.split(separator: "\n").first { $0.hasPrefix("KEYS: ") },
      "config --help に KEYS: 行が無い: \(outcome.stdout)")
    let listed = line.dropFirst("KEYS: ".count).split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertEqual(
      Set(listed), Set(SettingsRegistry.all.map(\.key)),
      "config --help の KEYS が SettingsRegistry と食い違っている")
  }

  /// `--workspace` に**値を必須で**取るコマンドの USAGE 行は、その値が `<id|current>` だと示す。
  ///
  /// `current` は数値 id と対等な指定で、受け付ける側は全ドメイン共通の 1 実装
  /// （`testWorkspaceFlagIsStrictWhereSpecRequiresAnId` が振る舞いを固定している）。
  ///
  /// どの行を測るかは binary 自身に決めさせる: bare `--workspace` が `requires an <id>` で落ちる
  /// コマンドが値必須。config は bare が正当な 3 態目なので外れ、そちらの `current` は
  /// `config --help` の本文が説明する（spec の書き分けを表面的な一貫性で潰さない）。
  /// 見るのは値の綴りだけで、行の体裁は測らない。
  func testUsageShowsCurrentWhereTheWorkspaceFlagRequiresAValue() throws {
    let help = ControlProcess.orbWithoutServer(["--help"])
    XCTAssertEqual(help.status, 0, "orb --help は socket 不達でも exit 0: \(help.stderr)")
    let usageLines = help.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .drop { $0 != "USAGE:" }.dropFirst()
      .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.contains("--workspace") }
    XCTAssertFalse(usageLines.isEmpty, "USAGE に --workspace を持つ行が無い: \(help.stdout)")

    var measured: [String] = []
    for line in usageLines {
      // 行頭の `orb <domain> <sub>` がコマンド。`[` / `<` / `(` で始まるトークンから先は引数の形。
      let command = line.split(separator: " ").dropFirst()
        .prefix { !"[<(".contains($0.first ?? " ") }.map(String.init)
      let bare = ControlProcess.orbWithoutServer(command + ["--workspace"])
      guard bare.stderr.contains("--workspace requires an <id>") else { continue }
      measured.append(line)
      XCTAssertTrue(
        line.contains("--workspace <id|current>"),
        "値必須の --workspace が current も取ることを usage が示していない: \(line)")
    }
    XCTAssertFalse(
      measured.isEmpty, "値必須の --workspace を持つコマンドが 1 つも見つからない（判定の空振り）")
  }
}
