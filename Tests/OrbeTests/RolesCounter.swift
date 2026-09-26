import AppKit
import OrbeEditorCore

/// 役割の問い合わせを記録する delegate（文書へも流す）。
@MainActor
final class RolesCounter: TextSurfaceDelegate {
  let inner: EditorDocument
  var queried: [NSRange] = []
  init(inner: EditorDocument) { self.inner = inner }
  func surface(_ surface: any TextSurface, rolesIn range: NSRange) -> [HighlightSpan] {
    queried.append(range)
    return inner.surface(surface, rolesIn: range)
  }
  func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    inner.surface(surface, didChange: edit)
  }
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    inner.surface(surface, focusDidChange: focused)
  }
  func surfaceDidChangeViewport(_ surface: any TextSurface) {
    inner.surfaceDidChangeViewport(surface)
  }
  func surfaceDidChangeSelection(_ surface: any TextSurface) {
    inner.surfaceDidChangeSelection(surface)
  }
  func surfaceLineCount(_ surface: any TextSurface) -> Int { inner.surfaceLineCount(surface) }
  func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    inner.surface(surface, lineContaining: offset)
  }
  func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    inner.surface(surface, rangeOfLine: line)
  }
}
