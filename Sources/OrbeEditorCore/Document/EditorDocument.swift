import CryptoKit
import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
  /// ディスクの内容が最後に読んだ／書いたものと違う。force でない保存はディスクに触れずこれで返る。
  case diskChanged(URL)
}

/// 開いたファイル 1 つ。識別（URL）・言語・未保存の有無・行索引・構文層を持ち、本文の正は対になる
/// テキスト面にある（開いてから閉じるまで 1 対 1）。面の delegate として編集を受け、索引と構文木を
/// 追従させて塗り直す。
///
/// 塗り直す範囲は「構文木が変わった区間 ∪ 今見えている区間」。木の差分だけでは、隣のノードの変化で
/// 役割が変わるのに自分の区間は変わらない字（呼び出しになった識別子など）が古い色のまま残る。
/// 見えている区間を毎回塗り直し、見えていない区間は次に見えたときに 1 回だけ塗る（`fresh` が
/// 「最後の編集の後に塗った区間」を持つ）。塗りは常に塗り直す区間の中に閉じる（→ `SyntaxLayer`）。
///
/// ディスクの姿（最後に読んだ／書いた内容のダイジェスト）も持ち、外部変更は監視の通知と保存の直前に
/// 実ファイルを読み直して比べる（`reconcileWithDisk` / `save`）。baseline（比べる底の本文）を持てば、
/// 本文との行差分（ハンク）を編集に追従させる。
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
  /// ディスクの内容が最後に読んだ／書いたものと違い、差し替えられていない（未保存の本文がある）。
  /// 照合のたびに導出し直す（読めない・消えた・同じ・差し替えたなら false）。
  public private(set) var isDiskChanged = false {
    didSet { if isDiskChanged != oldValue { onDiskChange?(isDiskChanged) } }
  }
  public var onDiskChange: ((Bool) -> Void)?
  /// テキスト面が first responder になった／やめた。
  public var onFocusChange: ((Bool) -> Void)?
  /// 比べる底の本文（index 版など）。無ければハンクは空。置くと即時にハンクを作り直す。
  public var baseline: String? {
    didSet {
      guard baseline != oldValue else { return }
      needsHunks = false
      rebuildHunks()
    }
  }
  /// baseline と本文の行差分。編集は runloop 1 回に間引いて作り直す。
  public private(set) var hunks: [LineHunk] = [] {
    didSet { if hunks != oldValue { onHunksChange?() } }
  }
  public var onHunksChange: (() -> Void)?
  private let syntax: SyntaxLayer?
  /// 最後の編集の後に塗った区間。編集のたびに（変わった区間 ∪ 可視区間）へ置き直す。
  private var fresh = IndexSet()
  /// 最後に読んだ／書いた内容のダイジェスト（UTF-8 に解いた本文のもの。BOM は解く時点で落ちる）。
  private var diskDigest: SHA256Digest
  private var needsHunks = false
  /// ディスクの内容で本文を差し替えている間は、その編集で未保存を立てない。
  private var isReplacingFromDisk = false

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
    let text = surface.text
    lineIndex = LineIndex(text: text)
    diskDigest = Self.digest(text)
    syntax = language.flatMap { registry.configuration(for: $0) }
      .flatMap { try? SyntaxLayer(configuration: $0, registry: registry) }
    surface.delegate = self
    if let syntax {
      highlight(syntax.parseAll(text, lineIndex: lineIndex), text: text)
      fresh = IndexSet(integersIn: 0..<text.utf16.count)
    }
  }

  /// 面の本文をそのまま UTF-8 で書く（改行・末尾改行は本文のまま）。保存は undo の区切りでもある。
  /// force でなければ直前にディスクと照合する（監視の通知が届く前でも同じ判定）——未編集なら差し替えて
  /// から書き、未保存の本文があれば `diskChanged` で失敗してディスクに触れない。
  public func save(force: Bool = false) throws {
    if !force {
      reconcileWithDisk()
      if isDiskChanged { throw EditorDocumentError.diskChanged(url) }
    }
    let text = surface.text
    try Data(text.utf8).write(to: url, options: .atomic)
    diskDigest = Self.digest(text)
    isDirty = false
    isDiskChanged = false
    surface.markUndoBoundary()
  }

  /// 実ファイルを読み直してディスクの姿と比べる。違っていて未保存でなければ本文を差し替え（undo 可、
  /// 未保存にならない、undo の区切り）、未保存なら `isDiskChanged` を立てて本文は保つ。
  /// 読めない（消えた・UTF-8 でない）ときと同じ内容のときは印を消す。
  public func reconcileWithDisk() {
    guard let onDisk = try? Self.read(url) else {
      isDiskChanged = false
      return
    }
    let digest = Self.digest(onDisk)
    guard digest != diskDigest else {
      isDiskChanged = false
      return
    }
    guard !isDirty else {
      isDiskChanged = true
      return
    }
    isReplacingFromDisk = true
    surface.replaceAll(with: onDisk)
    isReplacingFromDisk = false
    diskDigest = digest
    surface.markUndoBoundary()
    isDiskChanged = false
  }

  private static func digest(_ text: String) -> SHA256Digest {
    SHA256.hash(data: Data(text.utf8))
  }

  private func highlight(_ set: IndexSet, text: String) {
    guard let syntax, !set.isEmpty else { return }
    surface.applyHighlights(syntax.highlights(in: set, text: text), in: set)
  }

  private func rebuildHunks() {
    hunks = baseline.map { LineDiff.hunks(base: $0, current: surface.text) } ?? []
  }

  /// 打鍵ごとに差分を取らず、runloop 1 回に 1 度だけ作り直す。
  private func scheduleHunks() {
    guard baseline != nil, !needsHunks else { return }
    needsHunks = true
    Task { @MainActor [weak self] in
      guard let self, needsHunks else { return }
      needsHunks = false
      rebuildHunks()
    }
  }

  /// 今見えている区間（本文の長さに収めたもの）。
  private var visibleSet: IndexSet {
    let range = surface.visibleRange
    let end = min(NSMaxRange(range), surface.text.utf16.count)
    guard range.location < end else { return IndexSet() }
    return IndexSet(integersIn: range.location..<end)
  }
}

extension EditorDocument: TextSurfaceDelegate {
  public func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    let old = lineIndex
    lineIndex.apply(edit, replacement: surface.substring(in: edit.newRange))
    if !isReplacingFromDisk { isDirty = true }
    scheduleHunks()
    guard let syntax else { return }
    let text = surface.text
    var set = syntax.didChange(edit, text: text, old: old, new: lineIndex)
    set.formUnion(visibleSet)
    highlight(set, text: text)
    fresh = set
  }

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  /// 見える区間が動いた。最後の編集の後にまだ塗っていない部分だけ塗る。
  public func surfaceDidLayoutViewport(_ surface: any TextSurface) {
    guard syntax != nil else { return }
    let stale = visibleSet.subtracting(fresh)
    guard !stale.isEmpty else { return }
    highlight(stale, text: surface.text)
    fresh.formUnion(stale)
  }
}
