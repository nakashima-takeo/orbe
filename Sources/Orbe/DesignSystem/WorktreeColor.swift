import Foundation

/// worktree 識別色の番号決め。キー（worktree ルート／cwd）から `WorktreePalette.hex` の index を出す。
enum WorktreeColor {
  /// key の basename を NFC 正規化 → UTF-8 → FNV-1a 32bit → `hex.count` で剰余。
  /// 見本 theme.ts `worktreeColorIndex` と同じ符号化（UTF-16 だと非 ASCII 名で色が食い違う）。
  static func index(forKey key: String) -> Int {
    let name = (key as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
    var h: UInt32 = 0x811c_9dc5
    for b in name.utf8 {
      h ^= UInt32(b)
      h = h &* 0x0100_0193
    }
    return Int(h % UInt32(WorktreePalette.hex.count))
  }
}
