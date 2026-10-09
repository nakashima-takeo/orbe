import Foundation
import OrbeEditorCore

/// diff 1 つ——根の下の 1 つのパスの、古い側と新しい側と、その行差分。種類が側を決める——作業ツリー: index の版 ↔ 文書
/// （ファイルタブと同じ文書。開いていれば未保存を含む今の本文）／ステージ済み: HEAD の版（rename なら元のパス）↔ index の版。
///
/// 版の本文は根のサービスが 1 か所で持ち（→ `RootFiles.Version`）、diff はその状態から読むだけのリビジョンの文書を作る。
/// 作業ツリー diff の差分は文書のハンク（裏・版つき・編集でずらす）そのもので、古い側はそのハンクが比べた底から作る——
/// 底とハンクと今の本文の組は文書の中で食い違わないので、差し込みが古い側の本文とも今の本文ともずれない。
/// ステージ済み diff は両側とも変わらない版の本文なので、どちらかが変わったときに 1 回、裏で行差分を取る。
///
/// 見せ方（インライン / 並列）と見え方の付け外しは `present` / `dismiss` の 2 つの口だけで行い、pane が本体を置き換える
/// 1 か所から呼ぶ。見せていない間は版と文書の変化を追わず、見せたときに今の版で作り直す（打鍵中に隠れた diff が裏の仕事を
/// 起こさない）。
@MainActor
final class EditorDiff: RootFilesObserver {
  /// diff の上限——diff を出している間の行差分の上限。編集の数で切るので、大きなファイルの離れた変更も行ごとに取り、
  /// 裏の時間は 1MB 級でも 1 秒未満に収まる。
  static let hunkLimit = LineDiff.Limit.edits(10_000)

  let id: Key
  let files: RootFiles
  /// 作業ツリー diff の新しい側の文書（無ければ nil）。
  let document: EditorDocument?
  private let working: WorkingSide?
  private let surfaces: EditorSurfaces
  /// 古い側と、新しい側が版の本文のときの新しい側（その面も diff が持つ）。その版に無い側は空の本文。
  private(set) var old: RevisionDocument?
  private(set) var newRevision: RevisionDocument?
  private var newRevisionSurface: (any TextSurface)?
  /// 並列の古い側の面（並列で見せている間だけ）。
  private(set) var oldSurface: (any TextSurface)?
  /// 版の本文どうしの行差分（ステージ済み・作業ツリーで消したファイル。新しい側が文書の作業ツリー diff は、文書のハンクを
  /// 直に使う——`currentRows`）。
  private var revisionHunks: [LineHunk] = []
  private(set) var content: Content = .loading
  /// 面の焦点が変わった（古い側・新しい側の版の本文の面。作り直した文書にも結び直す）。
  var onFocusChange: ((Bool) -> Void)?
  /// 見せている見せ方（見せていなければ nil）。
  private(set) var presented: Mode?
  /// 中身・面・並びが変わった（見せている間だけ。pane が本体を置き直す）。
  var onPresentationChange: (() -> Void)?
  /// 今の古い側・新しい側の本文の元（その版に無ければ nil。まだ決めていなければ外側の nil）と大きさ。
  private var oldSource: String??
  private var newSource: String??
  private var oldSide = DiffRows.Side.absent
  private var newSide = DiffRows.Side.absent
  /// ステージ済みの側と行差分を頼んだ通し番号。
  private var stagedRequest = 0
  /// 見せていない間に変わった。
  private var stale = true
  /// 最初の変更区間へ送ったか。
  private var revealed = false

  init(id: Key, working: WorkingSide?, surfaces: EditorSurfaces) {
    self.id = id
    self.working = working
    self.surfaces = surfaces
    if case .document(let document) = working {
      self.document = document
    } else {
      document = nil
    }
    files = RootFiles.shared(for: id.root)
    files.addObserver(self, versions: interests)
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  // MARK: - 側

  /// 新しい側の面（作業ツリーなら文書の面、ほかは diff が持つ面。中身が見せられなければ nil）。
  var newSurface: (any TextSurface)? {
    guard content == .ready else { return nil }
    return document?.surface ?? newRevisionSurface
  }

  /// HEAD の版を引くパス（ステージ済みの rename なら元のパス）。
  private var headPath: String {
    files.status?.entries[id.path]?.originalPath ?? id.path
  }

  private var interests: Set<RootFiles.Version> {
    switch id.kind {
    case .workingTree: [RootFiles.Version(path: id.path, revision: .index)]
    case .staged:
      [
        RootFiles.Version(path: headPath, revision: .head),
        RootFiles.Version(path: id.path, revision: .index),
      ]
    }
  }

  // MARK: - 見せる

  /// 見せ方 `mode` で見せる——古い側・新しい側の本文と並びを今の版に合わせ、面に diff の見え方を載せる（新しい側は読む
  /// だけ）。並列なら古い側の面を作り、新しい側の面とスクロールを共にする。初めて見せるときは最初の変更区間へ送る。
  func present(_ mode: Mode) {
    let switching = presented != nil && presented != mode
    if switching { dropOldSurface() }
    presented = mode
    document?.onHunksChange = { [weak self] in self?.sourcesDidChange() }
    document?.hunkLimit = Self.hunkLimit
    if stale { refresh() } else { applyRows() }
  }

  /// 初めて画面に出す直前の、色の上限待ち（見えている範囲——インラインの古い側は見えている削除行——で効かせる）。
  func prepareToShow() {
    guard content == .ready else { return }
    viewportDidChange()
    old?.prepareToShow()
    newRevision?.prepareToShow()
    document?.prepareToShow()
  }

  /// 見せるのをやめる——古い側の面を閉じ（スクロールの共有が外れる）、文書の面にコードの見え方を戻し、文書のハンクを
  /// 追うのをやめる（次に見せるときに今の版で作り直す）。
  func dismiss() {
    guard presented != nil else { return }
    presented = nil
    stale = true
    dropOldSurface()
    guard let document else { return }
    document.onHunksChange = nil
    SurfaceLook.code.apply(to: document.surface, document: document)
  }

  private func dropOldSurface() {
    old?.detach()
    oldSurface?.view.removeFromSuperview()
    oldSurface = nil
  }

  /// 新しい側の面の見えている範囲が変わった（インラインでは古い側の見えている削除行を先に色付けする）。
  func viewportDidChange() {
    guard presented == .inline, let old, let surface = newSurface else { return }
    let text = document?.text ?? newRevision?.text ?? TextRope()
    guard let hunks = currentRows?.hunks else { return }
    let viewport = surface.viewport
    let first = text.row(containing: viewport.firstVisible)
    let last = first + Int(viewport.visibleLines.rounded(.up))
    old.setVisible(
      lines: DiffRows.oldLine(forNew: first, hunks)...DiffRows.oldLine(forNew: last, hunks))
  }

  /// 作業ツリー diff の文書の本文が変わった（見せている間に外部変更で差し替わった）。片側だけの diff は並びを今の行の数で
  /// 置き直す。
  func documentTextDidChange() {
    guard presented != nil, oldSource == .some(nil) else { return }
    sourcesDidChange()
  }

  // MARK: - 根のサービス

  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}

  /// status が変わった——競合の出入りと、ステージ済みの rename の元パス。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    files.setVersions(interests, for: self)
    sourcesDidChange()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    sourcesDidChange()
  }

  private func sourcesDidChange() {
    stale = true
    guard presented != nil else { return }
    refresh()
  }

  // MARK: - 作り直し

  /// 今の版の本文の状態から中身・側・行差分を作り直し、見せていれば並びを置く。
  private func refresh() {
    stale = false
    let next = resolve()
    if next != content {
      content = next
      if next != .ready { dropOldSurface() }
      onPresentationChange?()
    }
    applyRows()
  }

  /// 中身を決め、見せられるなら側と行差分を今の版に合わせる。
  private func resolve() -> Content {
    if files.status?.entries[id.path]?.isConflicted == true { return .unavailable(.conflicted) }
    switch id.kind {
    case .workingTree: return resolveWorkingTree()
    case .staged: return resolveStaged()
    }
  }

  private func resolveWorkingTree() -> Content {
    guard let working else { return .loading }
    if case .unavailable(let reason) = working { return .unavailable(reason) }
    let pending: Content = content == .ready ? .ready : .loading
    switch files.state(of: RootFiles.Version(path: id.path, revision: .index)) {
    case nil: return pending
    case .notText?: return .unavailable(.notText)
    case .failed?: return .unavailable(.failed)
    case .absent?: setOld(nil)
    case .text(let text)?:
      if let document {
        // 古い側は文書のハンクが比べた底——ハンクが新しい底に対する結果になるまでは、前の底とそのハンクの組のまま。
        guard let base = document.hunksBase else { return pending }
        setOld(base)
      } else {
        setOld(text)
      }
    }
    if document == nil {
      setNewRevision(nil)
      revisionHunks = DiffRows.wholeHunks(old: oldSide, new: .absent)
    }
    return .ready
  }

  /// ステージ済みは、両側の本文と行差分を裏で揃えてから一緒に入れ替える（届くまでは前の側と並びのまま）。
  private func resolveStaged() -> Content {
    let head = files.state(of: RootFiles.Version(path: headPath, revision: .head))
    let index = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    guard let head, let index else { return content == .ready ? .ready : .loading }
    for state in [head, index] {
      if state == .notText { return .unavailable(.notText) }
      if state == .failed { return .unavailable(.failed) }
    }
    stagedRequest += 1
    // 今の側と同じなら、走っている（別の本文の）依頼を捨てるだけ。
    guard oldSource != .some(head.text) || newSource != .some(index.text) else { return .ready }
    let request = stagedRequest
    let (oldText, newText, limit) = (head.text, index.text, Self.hunkLimit)
    Task.detached(priority: .userInitiated) {
      let (old, new) = (TextRope(oldText ?? ""), TextRope(newText ?? ""))
      let hunks =
        oldText != nil && newText != nil
        ? LineDiff.hunks(old: old, new: new, limit: limit)
        : DiffRows.wholeHunks(
          old: oldText == nil ? .absent : DiffRows.Side(old),
          new: newText == nil ? .absent : DiffRows.Side(new))
      await MainActor.run { [weak self] in
        guard let self, request == stagedRequest else { return }
        setOld(oldText)
        setNewRevision(newText)
        revisionHunks = hunks
        if content != .ready {
          content = .ready
          onPresentationChange?()
        }
        applyRows()
      }
    }
    return content == .ready ? .ready : .loading
  }

  /// 古い側を本文 `text`（その版に無ければ nil——空の本文で、大きさ 0 行）にする。変われば作り直す。
  private func setOld(_ text: String?) {
    guard oldSource != .some(text) else { return }
    oldSource = .some(text)
    dropOldSurface()
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    revision.onRolesChange = { [weak self] ranges in
      guard let self, presented == .inline, let surface = newSurface else { return }
      surface.rowSourceRolesDidChange(ranges)
    }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    old = revision
    oldSide = text == nil ? .absent : DiffRows.Side(revision.text)
  }

  /// 新しい側を版の本文 `text`（その版に無ければ nil——空の本文で、大きさ 0 行）にする。面は作り直さず、新しい本文の
  /// 文書へ結び直す。
  private func setNewRevision(_ text: String?) {
    guard newSource != .some(text) else { return }
    newSource = .some(text)
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    newRevision?.detach()
    revision.onViewportChange = { [weak self] in self?.viewportDidChange() }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    newRevision = revision
    newSide = text == nil ? .absent : DiffRows.Side(revision.text)
    if newRevisionSurface == nil { newRevisionSurface = surfaces.make() }
    if let surface = newRevisionSurface { revision.attach(surface) }
  }

  // MARK: - 並び

  /// 見せている見せ方の見え方を面に載せる（並列なら古い側の面を用意して結ぶ）。新しい側は読むだけで、作業ツリーの文書は
  /// diff の上限で行差分を取る。
  private func applyRows() {
    guard let mode = presented, content == .ready, let surface = newSurface, let old,
      let (hunks, newSide) = currentRows
    else { return }
    switch mode {
    case .inline:
      var rows = DiffRows.inline(hunks, old: oldSide, new: newSide)
      rows.source = old
      look(DiffStyle.inline, rows).apply(to: surface, document: document)
    case .side:
      let rows = DiffRows.side(hunks, old: oldSide, new: newSide)
      let left = oldSurface ?? makeOldSurface()
      if let left { look(DiffStyle.side, rows.left).apply(to: left, document: nil) }
      look(DiffStyle.side, rows.right).apply(to: surface, document: document)
      if let left, oldSurface == nil {
        oldSurface = left
        surface.shareScroll(with: left)
        onPresentationChange?()
      }
    }
    revealFirstChange(on: surface)
  }

  /// 今の古い側と新しい側の本文に対して正しいと分かっている行差分と、新しい側の大きさ。作業ツリー diff の新しい側の文書は
  /// 外の書き換えでいつでも変わるので、文書の今の本文と、文書のハンク（今の本文へずらしてある）を直に使い、ハンクが比べた底
  /// が今の古い側でなければ（古い側を入れ替える前）並べない——面に残っている並びは面自身の編集に付いて動くので、今の本文と
  /// 食い違わない。
  private var currentRows: (hunks: [LineHunk], newSide: DiffRows.Side)? {
    guard let document else { return (revisionHunks, newSide) }
    let side = DiffRows.Side(document.text)
    guard let oldSource else { return nil }
    guard let base = oldSource else { return (DiffRows.wholeHunks(old: .absent, new: side), side) }
    guard document.hunksBase == base else { return nil }
    return (document.hunks, side)
  }

  private func look(_ presentation: SurfacePresentation, _ rows: SurfaceRows) -> SurfaceLook {
    SurfaceLook(
      presentation: presentation, rows: rows, isEditable: false, hunkLimit: Self.hunkLimit)
  }

  private func makeOldSurface() -> (any TextSurface)? {
    guard let old, let surface = surfaces.make() else { return nil }
    old.attach(surface)
    return surface
  }

  /// 初めて並びを置いたときに、最初の変更区間が見える位置へ送る——区間の上の文脈の行から区間の終わりまで（インラインの
  /// 削除行はその間に差し込まれる）を、中央から、収まらなければ上端から見せる。
  private func revealFirstChange(on surface: any TextSurface) {
    guard !revealed, let first = currentRows?.hunks.first else { return }
    revealed = true
    let text = document?.text ?? newRevision?.text ?? TextRope()
    let start = first.newCount > 0 ? first.newStart - 1 : first.newStart
    let from = min(max(0, start - 1), text.lineCount - 1)
    let to = min(max(from, start + first.newCount - 1), text.lineCount - 1)
    surface.reveal(
      NSRange(location: text.lineStart(from), length: text.lineEnd(to) - text.lineStart(from)),
      policy: .center)
  }
}
