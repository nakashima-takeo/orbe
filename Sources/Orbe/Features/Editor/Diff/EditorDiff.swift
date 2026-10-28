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
/// 見せ方（インライン / 並列）と見え方の付け外しは `present` / `dismiss` の 2 つの口だけで行う。見せていない間は版と
/// 文書の変化を追わず、見せたときに今の版で作り直す（打鍵中に隠れた diff が裏の仕事を起こさない）。
@MainActor
final class EditorDiff: RootFilesObserver {
  /// diff の上限——diff を出している間の行差分の上限。編集の数で切るので、大きなファイルの離れた変更も行ごとに取り、
  /// 裏の時間は 1MB 級でも 1 秒未満に収まる。
  static let hunkLimit = LineDiff.Limit.edits(10_000)

  let id: Key
  let files: RootFiles
  /// 作業ツリーの姿（ステージ済みなら nil）と、それを読み直すべきか（ファイルが変わった）。
  var working: WorkingSide?
  var workingStale = true
  /// 作業ツリーのサブモジュールが取り出しているコミット（外側の nil はまだ読んでいない、内側の nil は取り出していない）と、
  /// 読みの通し番号（読み直しを頼めば前の読みの結果を捨てる）。
  var submoduleHead: String??
  var submoduleHeadRequest = 0
  var readsSubmoduleHead = false
  private(set) var documents: Documents
  let surfaces: EditorSurfaces
  /// 古い側と、新しい側が版の本文のときの新しい側（その面も diff が持つ）。その版に無い側も空の本文の文書を持つ（面は空の
  /// 行を 1 つ持つが、大きさ `oldSide`・`newRevisionSide` は 0 行で、その行に番号を描かない）。
  private(set) var old: RevisionDocument?
  private(set) var newRevision: RevisionDocument?
  private var newRevisionSurface: (any TextSurface)?
  /// 並列の古い側の面（並列で見せている間だけ）。
  var oldSurface: (any TextSurface)?
  /// 版の本文どうしの行差分（ステージ済み・作業ツリーで消したファイル。新しい側が文書の作業ツリー diff は、文書のハンクを
  /// 直に使う——`currentRows`）。
  var revisionHunks: [LineHunk] = []
  private(set) var content: Content = .loading
  /// 面の焦点が変わった（古い側・新しい側の版の本文の面。作り直した文書にも結び直す）。
  var onFocusChange: ((Bool) -> Void)?
  /// 見せている見せ方（見せていなければ nil）。
  private(set) var presented: Mode?
  /// 中身・面・並びが変わった（見せている間だけ。pane が本体を置き直す）。
  var onPresentationChange: (() -> Void)?
  /// 古い側が index のサブモジュール（文書の底ではない「Subproject commit」の行）。
  var oldIsSubmodule = false
  /// 今の古い側・新しい側の本文の元（その版に無ければ nil。まだ決めていなければ外側の nil）と大きさ。
  private(set) var oldSource: String??
  private var newSource: String??
  private(set) var oldSide = DiffRows.Side(nil)
  private(set) var newRevisionSide = DiffRows.Side(nil)
  /// ステージ済みの側と行差分を頼んだ通し番号と、側と並びが今の版の状態に揃っていないか（今の関心の版の状態がまだ無い・
  /// 頼んだ行差分が届いていない）。
  private var stagedRequest = 0
  private(set) var stagedPending = false
  /// 見せていない間に変わった。
  private var stale = true
  /// 初めての位置決めの段階。
  var placement = Placement.catchingUp
  /// 開いた後に頼んだ根のサービスの取り直し（status と版の本文）のうち、済んでいない数。
  private(set) var awaitedRefreshes = 2
  /// 開いた後の取り直しが済んでから、中身を決め直したか。
  private(set) var resolvedAfterCatchUp = false
  /// 面を置き換えた・外した（pane が本体を置き直す）。
  var surfacesChanged = false
  /// 新しい側の版の面を作り直したとき、新しい面で先頭に置く所。
  var carried: Carried?

  /// 作業ツリー diff は `documents`（セッション）から新しい側の文書を引く。テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗する。
  init(id: Key, documents: Documents, surfaces: EditorSurfaces) throws {
    self.id = id
    self.documents = documents
    self.surfaces = surfaces
    files = RootFiles.shared(for: id.root)
    if id.kind == .workingTree {
      workingStale = false
      working = try readWorkingTree(throwing: true)
      // 監視の知らせより先に開いても（エージェントが書いた直後の open_diff）、書いた中身で始める。
      document?.reconcileWithDisk()
    }
    files.addObserver(self, versions: interests)
    files.requestStatusRefresh { [weak self] in self?.refreshDidSettle() }
    files.requestVersionRefresh { [weak self] in self?.refreshDidSettle() }
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  // MARK: - 側

  /// 作業ツリー diff の新しい側の文書（作業ツリーの姿で変わる。無ければ nil）。
  var document: EditorDocument? {
    if case .document(let document)? = working { return document }
    return nil
  }

  /// 新しい側の面（作業ツリーなら文書の面、ほかは diff が持つ面。中身が見せられなければ nil）。
  var newSurface: (any TextSurface)? {
    guard content == .ready else { return nil }
    return document?.surface ?? newRevisionSurface
  }

  /// 新しい側の文書が `previous` から替わった——前の文書をファイルタブの見え方に戻し、今の文書のハンクを追う（見せて
  /// いれば）。面が替わるので古い側の面も閉じ、pane に置き直させる。今の文書で並びを置けるようになるまで、中身は
  /// 「読み込み中」（本体に何も出さない。開くときと同じ）。
  func documentDidSwitch(from previous: EditorDocument?) {
    dropOldSurface()
    surfacesChanged = true
    if document != nil { content = .loading }
    if presented != nil, let previous { restoreCode(previous) }
    guard presented != nil, let document else { return }
    document.onHunksChange = { [weak self] in self?.sourcesDidChange() }
    document.hunkLimit = Self.hunkLimit
  }

  // MARK: - 付け替え（cd で連が畳まれた）

  /// 新しい側の文書を引く口を `documents`（引き取ったセッション）に結び直す。
  func rebind(_ documents: Documents) {
    self.documents = documents
  }

  /// 新しい側を、同じ実体の文書 `next` にする（セッションが勝ち負けを決めた勝者。文書を持っていなければ、作業ツリーの
  /// 姿より未保存の `next` が先に立つ）。前の文書は手放さない（結線の後始末はセッションがまとめてする）。作り直しは
  /// 積むだけで、見せていれば `settle` で行う。
  func replaceDocument(with next: EditorDocument) {
    let previous = document
    guard previous !== next else { return }
    working = .document(next)
    documentDidSwitch(from: previous)
    stale = true
  }

  /// 新しい側の文書の未保存が変わった（セッションが配る）。未保存の間に保留した作業ツリーの読み直しを、未保存でなくなった
  /// 時点で行う。
  func documentDirtyDidChange() {
    guard workingStale, document?.isDirty == false else { return }
    sourcesDidChange()
  }

  /// 積んだ作り直しを、見せていれば今行う。
  func settle() {
    guard stale, presented != nil else { return }
    refresh()
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
    if let document { restoreCode(document) }
  }

  /// 文書の面をファイルタブの見え方に戻し、文書のハンクを追うのをやめる。
  private func restoreCode(_ document: EditorDocument) {
    document.onHunksChange = nil
    SurfaceLook.code.apply(to: document.surface, document: document)
  }

  /// 並列の古い側の面を閉じる（view を本体から外すのは pane——焦点を持っていれば、外す前に新しい行き先を決める）。
  private func dropOldSurface() {
    old?.detach()
    guard oldSurface != nil else { return }
    oldSurface = nil
    surfacesChanged = true
  }

  /// 面を置き換えた・外したら pane へ知らせる。
  private func settleSurfaces() {
    guard surfacesChanged else { return }
    surfacesChanged = false
    onPresentationChange?()
  }

  /// 新しい側の面の見えている範囲が変わった（インラインでは古い側の見えている削除行を先に色付けする）。
  func viewportDidChange() {
    guard presented != nil, let surface = newSurface else { return }
    if placement != .placed || carried != nil { placeFirstView(on: surface) }
    guard presented == .inline, let old, let hunks = currentRows?.hunks else { return }
    let viewport = surface.viewport
    old.setVisible(
      lines: DiffRows.oldLines(
        from: viewport.top, count: Int(viewport.visibleLines.rounded(.up)), hunks))
  }

  /// 作業ツリー diff の文書の本文が変わった（見せている間に外部変更で差し替わった）。片側だけの diff は並びを今の行の数で
  /// 置き直す。
  func documentTextDidChange() {
    guard presented != nil, oldSource == .some(nil) else { return }
    sourcesDidChange()
  }

  // MARK: - 根のサービス

  /// 作業ツリーのファイルが変わった——作業ツリー diff は、新しい側（文書・消えた・表示できない）を読み直す。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    guard id.kind == .workingTree, change.includes(id.root + "/" + id.path) else { return }
    workingStale = true
    sourcesDidChange()
  }

  /// status が変わった——競合の出入り・ステージ済みの rename の元パス・作業ツリーのサブモジュールの中の変化。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    files.setVersions(interests, for: self)
    forgetSubmoduleHead()
    sourcesDidChange()
  }

  /// 入れ子の git dir が変わった（監視の 1 バッチに 1 回）——作業ツリーのサブモジュールが取り出しているコミットを読み直す
  /// （中で続けてコミットしても、親の status は「コミットが動いた」のまま変わらない）。
  func rootFilesNestedGitStateDidChange(_ files: RootFiles) {
    guard case .directory? = working else { return }
    forgetSubmoduleHead()
    sourcesDidChange()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    sourcesDidChange()
  }

  /// 開いた後に頼んだ取り直しが 1 つ済んだ。両方済めば、その後の状態で作り直す。
  private func refreshDidSettle() {
    awaitedRefreshes -= 1
    if awaitedRefreshes == 0 { sourcesDidChange() }
  }

  func sourcesDidChange() {
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
      surfacesChanged = true
    }
    applyRows()
    settleSurfaces()
  }

  /// 中身を決め、見せられるなら側と行差分を今の版に合わせる。
  private func resolve() -> Content {
    // 走っている（前の本文の）ステージ済みの依頼は、ここでどの中身に決まっても捨てる——表示できないに決まった後に
    // 届いて上書きしない。
    stagedRequest += 1
    stagedPending = false
    if awaitedRefreshes == 0 { resolvedAfterCatchUp = true }
    if files.status?.entries[id.path]?.isConflicted == true { return .unavailable(.conflicted) }
    switch id.kind {
    case .workingTree: return resolveWorkingTree()
    case .staged: return resolveStaged()
    }
  }

  /// ステージ済みは、両側の本文と行差分を裏で揃えてから一緒に入れ替える（届くまでは前の側と並びのまま）。status で関心の
  /// 版が替わった（rename の元パス）直後など、今の関心の版の状態がまだ無い間も前の側と並びのまま待つ。
  private func resolveStaged() -> Content {
    let head = files.state(of: RootFiles.Version(path: headPath, revision: .head))
    let index = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    guard let head, let index else {
      stagedPending = true
      return content == .ready ? .ready : .loading
    }
    for state in [head, index] {
      if state == .notText { return .unavailable(.notText) }
      if state == .failed { return .unavailable(.failed) }
    }
    if head == .absent, index == .absent { return .unavailable(.nowhere) }
    let (oldText, newText, limit) = (Self.sideText(head), Self.sideText(index), Self.hunkLimit)
    // 今の側と同じなら、走っている依頼を捨てただけで済む。
    guard oldSource != .some(oldText) || newSource != .some(newText) else { return .ready }
    let request = stagedRequest
    stagedPending = true
    Task.detached(priority: .userInitiated) { [weak self] in
      let hunks = DiffRows.hunks(
        old: oldText.map(TextRope.init), new: newText.map(TextRope.init), limit: limit)
      await MainActor.run { [weak self] in
        guard let self, request == stagedRequest else { return }
        stagedPending = false
        let keepsOld = oldSource == .some(oldText)
        setOld(oldText)
        setNewRevision(newText, keepsOld: keepsOld)
        revisionHunks = hunks
        if content != .ready {
          content = .ready
          surfacesChanged = true
        }
        applyRows()
        settleSurfaces()
      }
    }
    return content == .ready ? .ready : .loading
  }

  /// 古い側を本文 `text`（その版に無ければ nil——空の本文の文書で、大きさは 0 行）にする。変われば作り直す。
  func setOld(_ text: String?) {
    guard oldSource != .some(text) else { return }
    oldSource = .some(text)
    dropOldSurface()
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    revision.onRolesChange = { [weak self] ranges in
      guard let self else { return }
      (document?.surface ?? newRevisionSurface)?.rowSourceRolesDidChange(ranges)
    }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    old = revision
    oldSide = DiffRows.Side(text == nil ? nil : revision.text)
  }

  /// 新しい側を版の本文 `text`（その版に無ければ nil——空の本文の文書で、大きさは 0 行）にする。文書と面は 1 対 1 なので、面も
  /// 作り直す——前の面で先頭に見えていた所を新しい面でも先頭に置き（`keepsOld` なら変わらない古い側の行を錨に写し、
  /// 古い側も変わるなら前の位置のまま）、並列なら古い側の面も作り直して新しい面と結ぶ。行差分（`revisionHunks`）は
  /// まだ前の並びのもの。
  func setNewRevision(_ text: String?, keepsOld: Bool) {
    guard newSource != .some(text) else { return }
    newSource = .some(text)
    if let previous = newRevisionSurface {
      let top = previous.viewport.top
      // 位置を決める前の作り直しは引き継がない（追いついた並びで 1 回だけ決める）。
      if placement == .placed {
        carried =
          keepsOld
          ? .anchor(DiffRows.anchor(at: top, revisionHunks, side: presented == .side))
          : .position(top)
      }
      dropOldSurface()
      surfacesChanged = true
    }
    let revision = RevisionDocument(text: text ?? "", name: id.url, registry: surfaces.registry)
    newRevision?.detach()
    revision.onViewportChange = { [weak self] in self?.viewportDidChange() }
    revision.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
    newRevision = revision
    newRevisionSide = DiffRows.Side(text == nil ? nil : revision.text)
    newRevisionSurface = surfaces.make()
    if let surface = newRevisionSurface { revision.attach(surface) }
  }
}
