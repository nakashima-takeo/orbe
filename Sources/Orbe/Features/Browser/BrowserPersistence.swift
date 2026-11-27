import Foundation

/// 内蔵ブラウザの永続入口。state の `browser/` フォルダの SQLite DB（`StateDatabase`）を開く。
enum BrowserPersistence {
  static let version: Int32 = 1
  static let migrations: [StateDatabase.Migration] = []

  static let defaultSheetRatioBps = 5200
  static let minSheetRatioBps = 2800
  static let maxSheetRatioBps = 8400

  static let defaultSheetRatio = Double(defaultSheetRatioBps) / 10000.0
  static let minSheetRatio = Double(minSheetRatioBps) / 10000.0
  static let maxSheetRatio = Double(maxSheetRatioBps) / 10000.0

  /// テスト用に DB のフォルダを差し替える（設定時はこちらを使う）。本番は nil。
  static var folderOverride: URL?

  static var folder: URL? {
    if let override = folderOverride { return override }
    return StateDir.base()?.appendingPathComponent("browser", isDirectory: true)
  }

  enum Opening {
    case opened(BrowserDatabase.Opened)
    case refused(String)
  }

  static func open(language: Language = .systemDefault, now: Date = Date()) -> Opening {
    guard let folder else {
      return .refused("browser database is unavailable: the state folder is unknown")
    }
    switch StateDatabase.open(
      folder: folder, version: version, schema: BrowserDatabase.schema, migrations: migrations,
      read: { try BrowserDatabase.loadOrSeed($0, language: language, now: now) })
    {
    case .opened(let opened):
      return .opened(
        BrowserDatabase.Opened(
          database: BrowserDatabase(opened.database),
          memory: opened.contents.memory,
          seededLanguage: opened.contents.seededLanguage))
    case .refused(let reason):
      return .refused("browser database is unavailable: the database \(reason)")
    }
  }

  /// 保存精度（ミリ秒整数）。メモリ上の時刻もこの精度へ揃えて DB 往復一致を保つ。
  static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  static func date(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: Double(millis) / 1000)
  }

  static func storedInstant(_ date: Date) -> Date {
    Self.date(Self.millis(date))
  }

  static func clampSheetRatio(_ ratio: Double) -> Double {
    guard ratio.isFinite else { return defaultSheetRatio }
    return min(maxSheetRatio, max(minSheetRatio, ratio))
  }

  static func clampSheetRatioBps(_ bps: Int) -> Int {
    min(maxSheetRatioBps, max(minSheetRatioBps, bps))
  }

  static func ratioBps(from ratio: Double) -> Int {
    clampSheetRatioBps(Int((clampSheetRatio(ratio) * 10000).rounded()))
  }

  static func ratio(fromBps bps: Int) -> Double {
    Double(clampSheetRatioBps(bps)) / 10000.0
  }
}
