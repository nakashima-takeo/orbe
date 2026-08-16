import Foundation
import XCTest

@testable import Orbe

/// `orb --help` が**写している語彙**を、写し元と突き合わせて固定する。
///
/// help は socket 不達でも出す必要があるため、control に問い合わせて組むことができない。そのため
/// key 名も設定 key も CLI 側に写しが置かれており、写しは黙ってドリフトする——実際に
/// `config --help` から 3 key が消えたまま出荷された。
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
}
