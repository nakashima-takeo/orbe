import Foundation

@testable import Orbe

// テストと見本が使う、本番には無い自動化の近道（本番の書き込みは確かめる `check` と掛ける `apply` を分けて通り、出力の行の
// `id` は型に組んで読む）。

extension AutomationStore {
  func create(_ definition: AutomationDefinition, now: Date) throws(AutomationError) -> Automation {
    try apply(try check(.create(definition)), now: now).automation
  }

  /// `version` は書き換えの元にした版。
  func replace(
    _ id: Int, version: Int?, with definition: AutomationDefinition, now: Date
  ) throws(AutomationError) -> Written {
    try apply(try check(.replace(id, version: version, definition)), now: now)
  }
}

extension AutomationPrompts {
  /// 行の `id`（文字列でなければ nil）。
  static func id(of row: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any]
    else { return nil }
    return object["id"] as? String
  }
}
