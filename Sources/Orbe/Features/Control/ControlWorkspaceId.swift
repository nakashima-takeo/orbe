import Foundation

/// params の `workspaceId` の読み口。workspace の ID を読む動詞はすべてここを通る。書くなら `Workspace.id` の UUID の文字列
/// （大文字小文字を問わない）で、それ以外の値（整数・真偽値・UUID でない文字列）は -32602——省略は動詞の既定の workspace を
/// 指すので、型違いを省略と読むと別の workspace を触る。今の workspace に解くのは target の側（無ければ -32004）。
enum ControlWorkspaceId {
  private static let key = "workspaceId"

  /// 省略できる欄。nil は省略。
  static func optional(_ params: [String: Any]) throws(ControlError) -> UUID? {
    guard let raw = params[key] else { return nil }
    return try id(raw)
  }

  static func required(_ params: [String: Any]) throws(ControlError) -> UUID {
    guard let raw = params[key] else {
      throw ControlError(code: -32602, message: "missing workspaceId")
    }
    return try id(raw)
  }

  /// `null` で「なし」にできる欄（タスクの付き先）。nil は省略。
  static func clearable(_ params: [String: Any]) throws(ControlError) -> ClearableValue<UUID>? {
    guard let raw = params[key] else { return nil }
    if raw is NSNull { return .clear }
    return .set(try id(raw))
  }

  private static func id(_ raw: Any) throws(ControlError) -> UUID {
    guard let text = raw as? String, let id = UUID(uuidString: text) else {
      throw ControlError(code: -32602, message: "invalid workspaceId")
    }
    return id
  }
}
