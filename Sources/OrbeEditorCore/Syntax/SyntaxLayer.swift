import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

/// 文書 1 つの構文木（injections 込みの `LanguageLayer`）。解析し、編集を追い、役割付き区間を発行する。
/// 単位は UTF-16（tree-sitter の既定符号化）。バイトはその 2 倍。
public final class SyntaxLayer {
  private let layer: LanguageLayer

  init(configuration: LanguageConfiguration, registry: LanguageRegistry) throws {
    layer = try LanguageLayer(
      languageConfig: configuration,
      configuration: LanguageLayer.Configuration(languageProvider: registry.languageProvider))
  }

  /// 本文全体を初めて解析する。
  func parseAll(_ text: String, lineIndex: LineIndex) -> IndexSet {
    let length = text.utf16.count
    let edit = InputEdit(
      startByte: 0, oldEndByte: 0, newEndByte: length * 2, startPoint: .zero, oldEndPoint: .zero,
      newEndPoint: Self.point(at: length, in: lineIndex))
    return layer.didChangeContent(LanguageLayer.Content(string: text), using: edit)
  }

  /// 編集を構文木へ写して再解析し、塗り直すべき区間を返す。`old` は編集前の索引、`new` は編集後。
  func didChange(_ edit: TextEdit, text: String, old: LineIndex, new: LineIndex) -> IndexSet {
    let input = InputEdit(
      startByte: edit.range.location * 2, oldEndByte: NSMaxRange(edit.range) * 2,
      newEndByte: NSMaxRange(edit.newRange) * 2,
      startPoint: Self.point(at: edit.range.location, in: old),
      oldEndPoint: Self.point(at: NSMaxRange(edit.range), in: old),
      newEndPoint: Self.point(at: NSMaxRange(edit.newRange), in: new))
    return layer.didChangeContent(LanguageLayer.Content(string: text), using: input)
  }

  /// 区間集合に掛かる役割付き区間。並びは tree-sitter の優先順（後のものが上に塗られる）。
  func highlights(in set: IndexSet, text: String) -> [HighlightSpan] {
    guard let ranges = try? layer.highlights(in: set, provider: text.predicateTextProvider) else {
      return []
    }
    return ranges.compactMap { named in
      CaptureRoleMap.role(for: named.name).map { HighlightSpan(range: named.range, role: $0) }
    }
  }

  private static func point(at offset: Int, in index: LineIndex) -> Point {
    let p = index.point(at: offset)
    return Point(row: p.row, column: p.column * 2)
  }
}
