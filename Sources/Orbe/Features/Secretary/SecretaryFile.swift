import Foundation
import OrbeSessionLog

/// 秘書の記録のディスク表現（`secretary.json`）。秘書の会話 ID と、まだ届けていない頼みの列を持つ。どちらも変わるたびに
/// 保存する——Orbe を終了しても、人が打った頼みは消えない。
struct SecretaryFile: Codable, Equatable {
  var version: Int
  /// 秘書の会話（claude のセッション ID）。再起動の後に秘書のタブを見つける鍵で、タブが無いときの再開の鍵。
  var sessionId: String?
  /// まだ届けていない頼み（受けた順）。
  var pending: [SecretaryRequest]

  static let empty = SecretaryFile(
    version: SecretaryPersistence.version, sessionId: nil, pending: [])
}

/// 溜めた頼み 1 件。本文は受けた時点に組んで固定する（言語も受けた時点のもの）。届ける 1 行は、届けるときに受けた時刻と
/// 本文から組む（`SecretaryText.line`）。
///
/// 出どころの保存の値は、旧ビルドが読める形に写す。旧ビルドは `origin` を palette・wait の 2 値で厳密に読み、知らない値が
/// あると記録ごと退避に落とすが、知らない欄は無視する。だから Home のボードは `origin: palette` と `screen: board` に分けて
/// 書き、旧ビルドへ戻しても溜まった頼みを失わない（頭が「⌘⇧X から」になるだけ）。文字列との対応はこの読み書きだけが持つ。
struct SecretaryRequest: Codable, Equatable {
  let id: UUID
  let receivedAt: Date
  let origin: SecretaryOrigin
  /// 1 行の本文。
  let body: String

  init(id: UUID, receivedAt: Date, origin: SecretaryOrigin, body: String) {
    self.id = id
    self.receivedAt = receivedAt
    self.origin = origin
    self.body = body
  }

  private enum CodingKeys: String, CodingKey {
    case id, receivedAt, origin, screen, body
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    receivedAt = try c.decode(Date.self, forKey: .receivedAt)
    body = try c.decode(String.self, forKey: .body)
    switch try c.decode(String.self, forKey: .origin) {
    case "wait":
      origin = .wait
    case "palette":
      origin = try c.decodeIfPresent(String.self, forKey: .screen) == "board" ? .board : .palette
    case let raw:
      throw DecodingError.dataCorruptedError(
        forKey: .origin, in: c, debugDescription: "unknown origin: \(raw)")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(receivedAt, forKey: .receivedAt)
    try c.encode(body, forKey: .body)
    switch origin {
    case .palette:
      try c.encode("palette", forKey: .origin)
    case .board:
      try c.encode("palette", forKey: .origin)
      try c.encode("board", forKey: .screen)
    case .wait:
      try c.encode("wait", forKey: .origin)
    }
  }
}

/// 頼みの出どころ（届ける 1 行の頭に出す）。頼む側が渡す。保存の値は `SecretaryRequest` の読み書きが決める。
enum SecretaryOrigin: Equatable {
  /// ⌘⇧X の入力欄・タスクの行。
  case palette
  /// Home のボードの依頼の欄。
  case board
  /// 秘書の会話が付けた待ちの条件が解けた後の ⌘T。
  case wait
}

/// 秘書の記録の永続。保存先は workspaces.json と並ぶ `StateDir.base()/secretary.json`。
enum SecretaryPersistence {
  static let version = 1

  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  /// 使えなかった原本の退避と、退避できなかった原本への書き込み停止。`load()` が毎回更新する。
  private static var quarantine = StateFileQuarantine()

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("secretary.json")
  }

  /// 読み込み。不在は nil。在るのに使えない原本（読めない・構造破損・非互換 version・再開に使えない会話 ID・1 行で
  /// ない本文）は退避してから nil を返す——人が打った頼みが、直後の保存で潰れて戻らないため。
  static func load() -> SecretaryFile? {
    quarantine.reset()
    guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url), let file = decode(data) else {
      quarantine.quarantine(url)
      return nil
    }
    return file
  }

  private static func decode(_ data: Data) -> SecretaryFile? {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let date = SessionEvent.parseISO8601(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(raw)"))
      }
      return date
    }
    guard let file = try? dec.decode(SecretaryFile.self, from: data), file.version == version,
      file.sessionId.map(AgentCatalog.isSafeSessionId) ?? true,
      file.pending.allSatisfy({ (try? TaskStore.validLine($0.body, "body")) == $0.body })
    else { return nil }
    return file
  }

  static func save(_ file: SecretaryFile) {
    guard let url = fileURL, quarantine.permitsWrite(to: url) else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(SessionEvent.iso8601(date))
    }
    guard let data = try? enc.encode(file) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
