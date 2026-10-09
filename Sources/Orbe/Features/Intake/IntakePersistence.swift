import Foundation
import OrbeSessionLog

/// 受信と提案のディスク表現。定義も蓄積も 1 ファイルに置き、1 回の確定を 1 度の書き込みにする。
struct IntakesFile: Codable, Equatable {
  var version: Int
  /// 次に振る ID。削除した ID を使い回さないために、一覧とは別に持つ。
  var nextIntakeId: Int
  var nextProposalId: Int
  var intakes: [Intake]
  var proposals: [IntakeProposal]
}

/// 受信の永続（自前 JSON）。保存先は tasks.json と並ぶ `StateDir.base()/intakes.json`。書くのは `IntakeStore` の変異ごと。
enum IntakePersistence {
  static let version = 1

  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  private static var quarantine = StateFileQuarantine()

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("intakes.json")
  }

  /// 読み込み。不在は nil。在るのに使えない原本——読めない・構造破損・非互換 version・定義の不正・ID とリンクの
  /// 不変条件の破れ——は退避してから nil を返す（AI と人が作った定義で、直後の保存が原本を潰すと戻らないため）。
  static func load() -> IntakesFile? {
    quarantine.reset()
    guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url), let file = decode(data) else {
      quarantine.quarantine(url)
      return nil
    }
    return file
  }

  private static func decode(_ data: Data) -> IntakesFile? {
    guard let file = try? IntakeWire.decoder.decode(IntakesFile.self, from: data),
      file.version == version
    else { return nil }
    let ids = file.intakes.map(\.id)
    let proposalIds = file.proposals.map(\.id)
    let links = file.proposals.map(\.item.link)
    guard file.nextIntakeId >= 1, file.nextProposalId >= 1,
      Set(ids).count == ids.count, ids.allSatisfy({ $0 >= 1 && $0 < file.nextIntakeId }),
      Set(proposalIds).count == proposalIds.count,
      proposalIds.allSatisfy({ $0 >= 1 && $0 < file.nextProposalId }),
      Set(links).count == links.count,
      file.intakes.allSatisfy({ (try? IntakeStore.valid($0.definition)) == $0.definition })
    else { return nil }
    return file
  }

  static func save(_ file: IntakesFile) {
    guard let url = fileURL, quarantine.permitsWrite(to: url),
      let data = try? IntakeWire.encoder(pretty: true).encode(file)
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}

/// intakes.json と制御 API が共有する JSON の書き方（時刻は ISO 8601・ミリ秒・Z）。
enum IntakeWire {
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
