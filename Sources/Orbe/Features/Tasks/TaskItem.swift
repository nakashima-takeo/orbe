import Foundation
import OrbeSessionLog

/// タスク 1 件。一覧（`TaskStore.tasks`）は人と agent が共有する 1 本の列で、この値はその要素。
/// 不変条件（ID の一意・タイトルと待ちの理由が空でない・完了は待ちを持たない）は `TaskStore` が保証する。
struct TaskItem: Codable, Equatable, Identifiable {
  /// 永続の短い整数。使い回さない（採番位置は `TasksFile.nextId` が持つ）。
  let id: Int
  var title: String
  var status: Status
  var waiting: Waiting?
  var priority: Priority
  var due: DueDate?
  /// 付き先の `Workspace.persistentId`。解決できない参照は「なし」と同じに扱う（削除された workspace を
  /// 指していても書き換えない）。
  var workspace: UUID?
  /// 人も agent も読む前提の自由記述（複数行可）。
  var memo: String
  let createdAt: Date
  /// 追加した agent の command 名。人が足したタスクは nil。
  let createdBy: String?

  enum Status: String, Codable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done
  }

  enum Priority: String, Codable, CaseIterable {
    case high, medium, low
  }

  /// 待ち。ステータスとは独立した属性で、完了にすると外れる。
  struct Waiting: Codable, Equatable {
    var reason: String
    /// 待ち始めた日時。理由だけを変えても動かない。
    var since: Date
  }

  /// 期限。時刻とタイムゾーンを持たない暦日。
  struct DueDate: Equatable, Codable {
    let year: Int
    let month: Int
    let day: Int

    /// `YYYY-MM-DD` で、暦として存在する日付だけを受ける。
    init?(_ text: String) {
      let parts = text.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
        parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
        let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
      else { return nil }
      let calendar = Calendar(identifier: .gregorian)
      guard y >= 1, (1...12).contains(m),
        let firstOfMonth = calendar.date(from: DateComponents(year: y, month: m)),
        calendar.range(of: .day, in: .month, for: firstOfMonth)?.contains(d) == true
      else { return nil }
      year = y
      month = m
      day = d
    }

    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let parsed = DueDate(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not a calendar date: \(raw)"))
      }
      self = parsed
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      try c.encode(text)
    }
  }
}

extension TaskItem {
  /// 永続とワイヤに載る時刻の精度（ミリ秒）へ丸める。丸めずに持つと、保存して読み戻した値が
  /// メモリ上の値と一致しない。
  static func storedInstant(_ date: Date) -> Date {
    SessionEvent.parseISO8601(SessionEvent.iso8601(date)) ?? date
  }
}

/// 追加の要求。`workspace` と `createdBy` は呼び出し元の文脈から埋める。
struct TaskDraft {
  var title: String
  var status: TaskItem.Status = .todo
  var priority: TaskItem.Priority = .medium
  var due: TaskItem.DueDate?
  var waitingReason: String?
  var memo = ""
  var workspace: UUID?
  var createdBy: String?
}

/// JSON の `null` に当たる「外す」を、値の指定と区別して運ぶ。
enum ClearableValue<Value> {
  case set(Value)
  case clear

  var value: Value? {
    if case .set(let v) = self { return v }
    return nil
  }
}

/// 変更の要求。nil の項目は変えない。
struct TaskUpdate {
  var title: String?
  var status: TaskItem.Status?
  var priority: TaskItem.Priority?
  var due: ClearableValue<TaskItem.DueDate>?
  var waitingReason: ClearableValue<String>?
  var memo: String?
  var workspace: ClearableValue<UUID>?

  var isEmpty: Bool {
    title == nil && status == nil && priority == nil && due == nil && waitingReason == nil
      && memo == nil && workspace == nil
  }
}
