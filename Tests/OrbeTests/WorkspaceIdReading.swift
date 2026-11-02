import Foundation

/// 外の口が返した workspace の ID（UUID の文字列）を読む。文字列でも UUID でもなければ nil。
func workspaceUUID(_ value: Any?) -> UUID? {
  (value as? String).flatMap(UUID.init(uuidString:))
}
