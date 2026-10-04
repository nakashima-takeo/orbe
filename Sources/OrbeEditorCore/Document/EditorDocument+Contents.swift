import CryptoKit
import Foundation

extension EditorDocument {
  /// ファイルから読んだ内容。本文のほかに、ディスクの姿と BOM の有無を持つ（文書がそのまま引き継ぐ）。
  public struct Contents {
    public let text: String
    let digest: SHA256Digest
    let hasBOM: Bool
  }

  static let bom = Data([0xEF, 0xBB, 0xBF])

  /// ファイルを UTF-8 として読む。読めない・UTF-8 でないは throw。先頭の BOM は本文に含めない。
  public static func read(_ url: URL) throws -> Contents {
    guard let data = try? Data(contentsOf: url) else { throw EditorDocumentError.unreadable(url) }
    let hasBOM = data.starts(with: bom)
    guard let text = String(data: hasBOM ? data.dropFirst(bom.count) : data, encoding: .utf8)
    else { throw EditorDocumentError.notUTF8(url) }
    return Contents(text: text, digest: SHA256.hash(data: data), hasBOM: hasBOM)
  }
}
