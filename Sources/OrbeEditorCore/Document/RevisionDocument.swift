import Foundation
import os

/// 版の本文を読むだけで持つ文書——diff の古い側と、ステージ済みの diff の新しい側。本文は変わらない（中身が変われば作り
/// 直す）ので、版は進まず、編集のずらし・ハンク・検索・保存・外部変更は持たない。ファイルを読まず、git も知らない——本文の
/// 文字列と、言語を決める名前だけを受ける。
///
/// 写し（本文と役割の並び）を持ち、結んだ面（読むだけ）の delegate として写しを引かせ、差し込んだ行の出どころとして別の面
/// にも引かせる。構文の色は文書と同じ裏の仕事が作り、役割が変わると結んだ面と `onRolesChange` に知らせる。見えている範囲は
/// 結んだ面から受けるほか、面が無くても `setVisible` で受ける（インラインの diff は、新しい側の面の見えている範囲を古い側の
/// 行へ写して渡す）——見えている削除行の色を先に作る。
@MainActor
public final class RevisionDocument {
  public let language: SyntaxLanguage?
  public private(set) var text: TextRope
  public private(set) var roles: RoleRuns
  /// 結んだ面（読むだけ。持ち主は面を作った側）。
  public private(set) weak var surface: (any TextSurface)?
  /// 役割が変わった（区間は写しの座標）。差し込んだ行の出どころとして引いている面へ配る口。
  public var onRolesChange: ((IndexSet) -> Void)?
  /// 結んだ面が first responder になった／やめた。
  public var onFocusChange: ((Bool) -> Void)?
  /// 結んだ面の見えている範囲が変わった。
  public var onViewportChange: (() -> Void)?
  /// 結んだ面の選択が変わった。
  public var onSelectionChange: (() -> Void)?

  private let inbox = AnalysisInbox()
  private var reception: SyntaxReception
  private let log = EditLog()

  /// 本文 `text` の、名前 `name` から言語を決めた文書。構文の裏の仕事はここで起きる（待たない）。
  public convenience init(text: String, name: URL, registry: LanguageRegistry) {
    self.init(text: text, name: name, registry: registry, quietDelay: SyntaxWorker.quietDelay)
  }

  init(text: String, name: URL, registry: LanguageRegistry, quietDelay: DispatchTimeInterval) {
    language = SyntaxLanguage.detect(url: name)
    let rope = TextRope(text)
    self.text = rope
    roles = RoleRuns(length: rope.length)
    reception = SyntaxReception(
      text: rope, version: 0, language: language, registry: registry, inbox: inbox,
      quietDelay: quietDelay)
    inbox.setWake { [weak self] in self?.receive() }
  }

  /// 閉じた文書の大きな部品を裏で手放す口（文書と同じ）。
  var releaseParts: @Sendable (OSAllocatedUnfairLock<ReleasedParts?>) -> Void = { parcel in
    DispatchQueue.global(qos: .utility).async { parcel.withLock { $0 = nil } }
  }

  /// 走っている解析を打ち切らせ、写し・役割の並び・構文木を持つ裏の仕事を裏で手放す。
  deinit {
    let parcel = OSAllocatedUnfairLock<ReleasedParts?>(
      initialState: ReleasedParts(
        text: text, synced: TextRope(), roles: roles, syntax: reception.release()))
    text = TextRope()
    roles = RoleRuns(length: 0)
    releaseParts(parcel)
  }

  /// 面を結ぶ——読むだけにし、本文の作法（字下げ・改行）を押し、面の delegate になる（面は写しを引く）。
  public func attach(_ surface: any TextSurface) {
    surface.isEditable = false
    surface.setIndentation(Indentation.detect(in: text.utf16))
    surface.setLineBreak(LineBreak.detect(in: text.utf16))
    self.surface = surface
    surface.delegate = self
  }

  /// 結んだ面を外す（面は delegate を失う）。
  public func detach() {
    if surface?.delegate === self { surface?.delegate = nil }
    surface = nil
  }

  /// 見えている行（写しの行）。構文の裏の仕事が、次の区切りからそこを先に作る。
  public func setVisible(lines: ClosedRange<Int>) {
    reception.setVisible(lines, in: text)
  }

  /// 初めて画面に出す直前に呼ぶ（2 回目以降は何もしない）。見えている範囲の色が揃っていなければ、最大
  /// `EditorDocument.firstColorsWait` 待つ。
  public func prepareToShow() {
    guard reception.beginShowing(ready: isFirstColorReady) else { return }
    _ = wait(until: .now() + SyntaxReception.firstColorsWait) { $0.isFirstColorReady }
  }

  /// 構文の裏の仕事が全体を作り終え、その結果を受け取るまで待つ（最大 `timeout`）。追いついたら true。
  @discardableResult
  public func waitUntilCaughtUp(timeout: TimeInterval = 5) -> Bool {
    SyntaxReception.hurrying(reception.worker) {
      wait(until: .now() + timeout) { $0.reception.isComplete(at: 0) }
    }
  }

  private var isFirstColorReady: Bool { reception.isFirstColorReady(at: 0) }

  private func wait(until deadline: DispatchTime, _ done: (RevisionDocument) -> Bool) -> Bool {
    SyntaxReception.wait(on: inbox, until: deadline, receive: receive) { done(self) }
  }

  private func receive() {
    let contents = inbox.take()
    let changed = reception.receive(contents.syntax, roles: &roles) { log.edits(since: $0) }
    guard !changed.isEmpty else { return }
    surface?.rolesDidChange(changed)
    onRolesChange?(changed)
  }
}

extension RevisionDocument: TextSurfaceDelegate {
  /// 結んだ面は読むだけで、本文を変えない（載せる側も丸ごとの置き換えを呼ばない）。
  public func surface(_ surface: any TextSurface, didChange edits: [TextEdit]) {
    preconditionFailure("リビジョンの文書の面は読むだけ")
  }

  public func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    onFocusChange?(focused)
  }

  public func surfaceDidChangeViewport(_ surface: any TextSurface) {
    reception.setVisible(SyntaxReception.lines(of: surface.viewport, in: text), in: text)
    onViewportChange?()
  }

  public func surfaceDidChangeSelection(_ surface: any TextSurface) {
    onSelectionChange?()
  }

  public func surfaceContent(_ surface: any TextSurface) -> SurfaceContent {
    rowSourceContent
  }
}

extension RevisionDocument: SurfaceRowSource {
  public var rowSourceContent: SurfaceContent {
    SurfaceContent(text: text, roles: roles, version: 0)
  }
}
