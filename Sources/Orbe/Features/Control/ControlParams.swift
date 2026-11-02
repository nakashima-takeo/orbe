import Foundation

/// 引数の型。動詞の表の行が受ける鍵ごとに持ち、読み手はこの型で値を確かめる。
indirect enum ControlParamType: Equatable {
  /// 整数。真偽値は受けない（JSONSerialization は true / false も NSNumber に載せ `as? Int` を通す）。
  case int
  case bool
  case string
  case strings
  /// JSON オブジェクト。中身はそのオブジェクトを読む持ち主が自分の欄で照らす。
  case object
  case objects
  /// workspace の ID（`Workspace.id` の UUID の文字列。大文字小文字を問わない）。省略は動詞の既定の workspace を指すので、
  /// 型違いを省略と読むと別の workspace を触る。今の workspace に解くのは target の側（無ければ -32004）。
  case workspaceId
  /// JSON の値なら何でも（値の検証は受け手が持つ）。
  case any
  /// `null` で外せる値。鍵が無いのは省略で、`null` とは別。
  case clearable(ControlParamType)
}

/// 動詞の引数の読み手。動詞の表の行（受ける鍵と型）から作り、行に無い鍵があれば作れない（`unknown <鍵>`）。値は読むときに
/// 行の型で確かめ、違えば `invalid <鍵>`——どの動詞も型違いを省略と同じに読まない。ハンドラは引数をここからだけ読み、宛先の
/// 解決と値の確かめより先に全部読む。行に無い鍵を読むのはプログラムの誤り（テストの中で落ちる）。
struct ControlParams {
  /// 要求の封筒が伝える呼び出し元のタブ（引数ではない）。
  let callerTabId: Int?
  private let values: [String: Any]
  private let types: [String: ControlParamType]
  /// 入れ子のオブジェクトの欄の場所の前置き（`condition.`・`links[0].`）。
  private let prefix: String

  init(
    _ values: [String: Any], accepting types: [String: ControlParamType], prefix: String = "",
    callerTabId: Int? = nil
  ) throws(ControlError) {
    if let unknown = values.keys.sorted().first(where: { types[$0] == nil }) {
      throw ControlError(code: -32602, message: "unknown \(prefix)\(unknown)")
    }
    self.values = values
    self.types = types
    self.prefix = prefix
    self.callerTabId = callerTabId
  }

  /// 要求の封筒が持つ鍵。
  private static let envelopeKeys: Set = ["jsonrpc", "id", "method", "params", "caller"]

  /// 要求の `params`（省いた要求は引数なし）と封筒の `caller`（`{tabId}`）から作る。封筒の知らない鍵も断る（書き損じた
  /// `params` や `caller` を省略と読まない）。
  init(request: [String: Any], accepting types: [String: ControlParamType]) throws(ControlError) {
    if let unknown = request.keys.sorted().first(where: { !Self.envelopeKeys.contains($0) }) {
      throw ControlError(code: -32602, message: "unknown \(unknown)")
    }
    let values: [String: Any]
    switch request["params"] {
    case nil: values = [:]
    case let object as [String: Any]: values = object
    default: throw ControlError(code: -32602, message: "invalid params")
    }
    try self.init(values, accepting: types, callerTabId: try Self.caller(request["caller"]))
  }

  private static func caller(_ raw: Any?) throws(ControlError) -> Int? {
    guard let raw else { return nil }
    guard let object = raw as? [String: Any], object.count == 1,
      let tabId = object["tabId"].flatMap(Self.asInt)
    else { throw ControlError(code: -32602, message: "invalid caller") }
    return tabId
  }

  func missing(_ key: String) -> ControlError {
    ControlError(code: -32602, message: "missing \(prefix)\(key)")
  }

  func invalid(_ key: String) -> ControlError {
    ControlError(code: -32602, message: "invalid \(prefix)\(key)")
  }

  // MARK: - 読み

  func int(_ key: String) throws(ControlError) -> Int { try required(key, optionalInt(key)) }
  func optionalInt(_ key: String) throws(ControlError) -> Int? { try read(key, .int, Self.asInt) }

  func bool(_ key: String) throws(ControlError) -> Bool { try required(key, optionalBool(key)) }
  func optionalBool(_ key: String) throws(ControlError) -> Bool? {
    try read(key, .bool, Self.asBool)
  }

  func string(_ key: String) throws(ControlError) -> String {
    try required(key, optionalString(key))
  }
  func optionalString(_ key: String) throws(ControlError) -> String? {
    try read(key, .string) { $0 as? String }
  }
  func clearableString(_ key: String) throws(ControlError) -> ClearableValue<String>? {
    try clearable(key, .string) { $0 as? String }
  }

  func strings(_ key: String) throws(ControlError) -> [String] {
    try required(key, optionalStrings(key))
  }
  func optionalStrings(_ key: String) throws(ControlError) -> [String]? {
    try read(key, .strings) { $0 as? [String] }
  }

  func object(_ key: String) throws(ControlError) -> [String: Any] {
    try required(key, optionalObject(key))
  }
  func optionalObject(_ key: String) throws(ControlError) -> [String: Any]? {
    try read(key, .object) { $0 as? [String: Any] }
  }
  func clearableObject(_ key: String) throws(ControlError) -> ClearableValue<[String: Any]>? {
    try clearable(key, .object) { $0 as? [String: Any] }
  }
  func optionalObjects(_ key: String) throws(ControlError) -> [[String: Any]]? {
    try read(key, .objects) { $0 as? [[String: Any]] }
  }

  /// 型を問わない値（`null` も値）。
  func value(_ key: String) throws(ControlError) -> Any {
    try required(key, read(key, .any) { $0 })
  }

  private static let workspaceKey = "workspaceId"

  func workspaceId() throws(ControlError) -> UUID {
    try required(Self.workspaceKey, optionalWorkspaceId())
  }
  func optionalWorkspaceId() throws(ControlError) -> UUID? {
    try read(Self.workspaceKey, .workspaceId, Self.asWorkspaceId)
  }
  /// `null` で「なし」にできる workspace の ID（タスクの付き先）。
  func clearableWorkspaceId() throws(ControlError) -> ClearableValue<UUID>? {
    try clearable(Self.workspaceKey, .workspaceId, Self.asWorkspaceId)
  }

  private func required<T>(_ key: String, _ value: T?) throws(ControlError) -> T {
    guard let value else { throw missing(key) }
    return value
  }

  private func read<T>(_ key: String, _ type: ControlParamType, _ cast: (Any) -> T?)
    throws(ControlError) -> T?
  {
    assert(types[key] == type, "\(prefix)\(key) is not a \(type) argument here")
    guard let raw = values[key] else { return nil }
    guard let value = cast(raw) else { throw invalid(key) }
    return value
  }

  private func clearable<T>(_ key: String, _ type: ControlParamType, _ cast: (Any) -> T?)
    throws(ControlError) -> ClearableValue<T>?
  {
    assert(types[key] == .clearable(type), "\(prefix)\(key) is not a clearable \(type) here")
    guard let raw = values[key] else { return nil }
    if raw is NSNull { return .clear }
    guard let value = cast(raw) else { throw invalid(key) }
    return .set(value)
  }

  private static func isBool(_ raw: Any) -> Bool {
    (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
  }

  private static func asInt(_ raw: Any) -> Int? { isBool(raw) ? nil : raw as? Int }

  private static func asBool(_ raw: Any) -> Bool? { isBool(raw) ? raw as? Bool : nil }

  private static func asWorkspaceId(_ raw: Any) -> UUID? {
    (raw as? String).flatMap(UUID.init(uuidString:))
  }
}
