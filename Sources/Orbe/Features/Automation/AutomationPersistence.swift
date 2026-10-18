import Foundation
import OrbeSessionLog

/// 自動化の永続。state の `automations/` フォルダの SQLite の DB（`StateDatabase`）に、自動化・部品の状態・溜まりの行・候補・
/// 回の記録を置く。形の変わりやすいもの（定義・前回の出力・出どころ・候補の項目・回の記録）は外の JSON のまま 1 列に、骨組みは
/// 列と索引と制約で持つ。書き手は `AutomationStore` だけ。
enum AutomationPersistence {
  static let version: Int32 = 1

  /// テスト用に DB のフォルダを差し替える（設定時はこちらを使う）。本番は nil。旧形式の JSON の場所もここから導く。
  static var folderOverride: URL?

  static var folder: URL? {
    if let override = folderOverride { return override }
    return StateDir.base()?.appendingPathComponent("automations", isDirectory: true)
  }

  /// 旧形式の `automations.json`（フォルダの隣）。読まない。
  static var legacyFile: URL? {
    folder?.deletingLastPathComponent().appendingPathComponent("automations.json")
  }

  /// 起動時に開いて全部を読む。旧形式の JSON があれば退避する（失敗しても続け、次の起動でやり直す）。開けない・確かめられない・
  /// 別の Orbe が持っているときは nil（そのセッションは自動化を読まず・走らせず・書かない）。
  static func open() -> AutomationDatabase.Opened? {
    if let legacy = legacyFile, FileManager.default.fileExists(atPath: legacy.path) {
      var quarantine = StateFileQuarantine()
      quarantine.quarantine(legacy)
    }
    guard let folder,
      let opened = StateDatabase.open(
        folder: folder, version: version, schema: AutomationDatabase.schema,
        read: AutomationDatabase.snapshot)
    else { return nil }
    return AutomationDatabase.Opened(
      database: AutomationDatabase(opened.database), snapshot: opened.contents)
  }

  /// 保存の精度（ミリ秒）。メモリの時刻はいつもこの精度に通してから持つ——読み直した値と同じにするため。
  static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  static func date(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: Double(millis) / 1000)
  }
}

/// 起動時に読んだ全部。
struct AutomationSnapshot: Equatable {
  var automations: [Automation]
  var proposals: [AutomationProposal]
}

/// 自動化の保存と制御 API が共有する JSON の書き方（時刻は ISO 8601・ミリ秒・Z）。
enum AutomationWire {
  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let date = SessionEvent.parseISO8601(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(raw)"))
      }
      return date
    }
    return decoder
  }

  static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(SessionEvent.iso8601(date))
    }
    return encoder
  }

  /// 制御 API の応答に載せる JSON 値。
  static func object(_ value: some Encodable) -> Any {
    guard let data = try? encoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [String: Any]() }
    return object
  }
}
