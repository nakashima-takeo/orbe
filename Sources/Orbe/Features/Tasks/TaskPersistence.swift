import Foundation
import OrbeSessionLog

/// タスク一覧のディスク表現。`tasks` の配列の順が列の順。
struct TasksFile: Codable, Equatable {
  var version: Int
  /// 次に振る ID。削除した ID を使い回さないために、一覧とは別に持つ。
  var nextId: Int
  var tasks: [TaskItem]
}

/// タスク一覧の永続（自前 JSON）。保存先は workspaces.json と並ぶ `StateDir.base()/tasks.json`。
/// 書くのは `TaskStore` の変異ごと（即時保存）。
enum TaskPersistence {
  static let version = 1

  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  /// 使えなかった原本の退避と、退避できなかった原本への書き込み停止。`load()` が毎回更新する。
  private static var quarantine = StateFileQuarantine()

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("tasks.json")
  }

  /// 読み込み。不在は nil（空の一覧で始める）。在るのに使えない原本——読めない・構造破損・
  /// 非互換 version・ID の不変条件の破れ（1 未満の採番位置を含む）・結び付きの不変条件の破れ——は
  /// 退避してから nil を返す。人が書き溜めた内容で、
  /// 直後の保存が原本を潰すと戻らないため。
  static func load() -> TasksFile? {
    quarantine.reset()
    guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url), let file = decode(data) else {
      quarantine.quarantine(url)
      return nil
    }
    return file
  }

  private static func decode(_ data: Data) -> TasksFile? {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let date = SessionEvent.parseISO8601(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(raw)"))
      }
      return date
    }
    guard let file = try? dec.decode(TasksFile.self, from: data), file.version == version else {
      return nil
    }
    let ids = file.tasks.map(\.id)
    guard file.nextId >= 1, Set(ids).count == ids.count,
      ids.allSatisfy({ $0 >= 1 && $0 < file.nextId })
    else {
      return nil
    }
    for (index, task) in file.tasks.enumerated() {
      do throws(TaskStoreError) {
        try TaskStore.checkLinks(task.links, of: task.id, against: Array(file.tasks[..<index]))
      } catch {
        return nil
      }
    }
    return file
  }

  static func save(_ file: TasksFile) {
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
