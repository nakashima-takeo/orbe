import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
}

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無・行索引・構文層を持ち、本文の正は対になる
/// テキスト面にある（開いてから閉じるまで 1 対 1）。面の delegate として編集を受け、索引と構文木を
/// 追従させて塗り直す。
@MainActor
public final class EditorDocument {
  public let url: URL
  public let language: SyntaxLanguage?
  public let surface: any TextSurface
  public private(set) var lineIndex: LineIndex
  /// 面の本文が最後に保存（または開いた）内容と違うか。⌘Z で保存時の状態に戻しても立ったまま。
  public private(set) var isDirty = false {
    didSet { if isDirty != oldValue { onDirtyChange?(isDirty) } }
  }
  public var onDirtyChange: ((Bool) -> Void)?
  /// テキスト面が first responder になった／やめた。
  public var onFocusChange: ((Bool) -> Void)?
  private let syntax: SyntaxLayer?

  /// ファイルを UTF-8 として読む。読めない・UTF-8 でないは throw。
  public static func read(_ url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url) else { throw EditorDocumentError.unreadable(url) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw EditorDocumentError.notUTF8(url)
    }
    return text
  }

  public init(url: URL, surface: any TextSurface, registry: LanguageRegistry) {
    self.url = url
    self.surface = surface
    language = SyntaxLanguage.detect(url: url)
    lineIndex = LineIndex(text: surface.text)
    syntax = language.flatMap { registry.configuration(for: $0) }
      .flatMap { try? SyntaxLayer(configuration: $0, registry: registry) }
    surface.delegate = self
    if let syntax {
      let text = surface.text
      let set = syntax.parseAll(text, lineIndex: lineIndex)
      surface.applyHighlights(syntax.highlights(in: set, text: text), in: set)
    }
  }

  /// 面の本文をそのまま UTF-8 で書く（改行・末尾改行は本文のまま）。
  public func save() throws {
    try Data(surface.text.utf8).write(to: url, options: .atomic)
    isDirty = false
  }

  /// 構文層から全区間を再発行する（外観切替などで色を解き直す口）。
  public func rehighlightAll() {
    guard let syntax else { return }
    let text = surface.text
    let all = IndexSet(integersIn: 0..<text.utf16.count)
    surface.applyHighlights(syntax.highlights(in: all, text: text), in: all)
  }
}

extension EditorDocument: TextSurfaceDelegate {
  public func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    let old = lineIndex
    lineIndex.apply(edit, replacement: surface.substring(in: edit.newRange))
    isDirty = true
    guard let syntax else { return }
    let text = surface.text
    let set = syntax.didChange(edit, text: text, old: old, new: lineIndex)
    surface.applyHighlights(syntax.highlights(in: set, text: text), in: set)
  }

  public func surfaceDidChangeSelection(_ surface: any TextSurface) {}

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  public func surfaceDidLayoutViewport(_ surface: any TextSurface) {}
}
