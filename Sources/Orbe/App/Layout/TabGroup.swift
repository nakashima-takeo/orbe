import AppKit
import OrbeEditorCore

/// workspace の中の連（同じ worktree のタブの並び）1 本に 1 つ。連のタブが共有するもの——エディターのセッション・面の配置と
/// 焦点の面・器（`GroupFacesView`）・開いていた文書の復元待ち——を持つ。連の中でタブを切り替えると、器の中の端末だけが
/// 入れ替わる。
///
/// 寿命は、それを所属に持つタブが居る間だけ。作る・付け替える・畳むのは `WindowController` だけで、キー K の連は
/// 「キー K のタブの所属」で引く（表は持たない）。器は AppKit の NSView のまま作り直さない（cf. `TerminalTab`）。
final class TabGroup {
  /// 連のキー＝worktree ルート（管理外は cwd 自身の正規形パス）。エディター面の根も同じ値。書くのは `rekey` だけ。
  private(set) var key: String
  /// 面の配置（エディター幅の割合・焦点の面）。正規形に限り、書き換えは `setFaces` だけが行う。
  private(set) var faces: FaceLayout
  /// エディターのセッション。書き手は連とその pane で、外（制御 API）は `openFile`・`openDiff` を通る。エディターの型は
  /// UI に閉じた `@MainActor` で、連はその外（main スレッド規律の nonisolated）にいるため、触る箇所は
  /// `MainActor.assumeIsolated` で境を越える。
  let editor: EditorSession
  /// mount 単位（エディター面・端末面と取っ手の器）。`WindowController` の照合が content へ載せる／隠す／外す。
  let view: GroupFacesView
  /// 未消費の復元状態（開いていた文書）。器が初めて content に載るとき（`materialize`）に消費する。一度も載らなければ
  /// 同じ形で書き戻す。
  private var pendingDocuments: EditorState.OpenDocuments?
  /// 器が一度でも content に載ったか。
  private var materialized = false

  /// 面の配置が変わった（永続保存・chrome 更新・焦点の追従は上位）。
  var onFacesChange: (() -> Void)?
  /// タブの列・焦点のタブ・未保存の有無・検索の問いが変わった（chrome 更新・永続保存は上位）。
  var onEditorChange: (() -> Void)?
  /// エディター面からのウィンドウレベルの chrome キーを上位へ届ける。
  var onWindowCommand: ((WindowCommand) -> Void)?

  init(key: String, state: GroupState? = nil, editorSurfaces: EditorSurfaces = .shared) {
    self.key = key
    faces = state?.faces.normalized ?? .terminalOnly
    editor = MainActor.assumeIsolated { EditorSession(surfaces: editorSurfaces) }
    view = GroupFacesView(editor: EditorPaneView(root: key), faces: faces)
    pendingDocuments = state?.editor?.documents
    wireView()
    if let search = state?.editor?.search {
      MainActor.assumeIsolated { view.editor.projectSearch.restore(search) }
    }
  }

  /// pane が連を知り、取っ手の求める配置が連の状態を通って器へ戻るよう配線する。セッションの変化は器（面の骨と中身）へ
  /// 写してから上位へ 1 本で上げる。
  private func wireView() {
    view.editor.group = self
    view.onFacesRequested = { [weak self] faces, animated in
      self?.setFaces(faces, animated: animated)
    }
    view.onFaceFocused = { [weak self] face in self?.paneDidFocus(face) }
    MainActor.assumeIsolated {
      editor.onChange = { [weak self] in
        guard let self else { return }
        view.editor.sessionDidChange()
        onEditorChange?()
      }
      view.editor.projectSearch.onQueryChange = { [weak self] in self?.onEditorChange?() }
      editor.onFocusChange = { [weak self] in self?.view.editor.focusDidChange() }
    }
  }

  /// 器が初めて content に載る。復元待ちの文書を開く（既に開いている文書は壊さない）。2 回目からは何もしない。
  func materialize() {
    guard !materialized else { return }
    materialized = true
    guard let pending = pendingDocuments.take() else { return }
    MainActor.assumeIsolated {
      editor.restore(paths: pending.open, active: pending.active, preview: pending.preview)
    }
  }

  /// 配置を書き換える唯一の口。正規化し、同じなら何もしない。器へ写し、上位へ通知する。
  func setFaces(_ faces: FaceLayout, animated: Bool) {
    let normalized = faces.normalized
    guard normalized != self.faces else { return }
    self.faces = normalized
    view.set(normalized, animated: animated)
    onFacesChange?()
  }

  /// first responder が面の配下に入った（器が告げる）。焦点の記憶を面に追従させる（面の外へ出ても触らない——パレットで
  /// 一時的に焦点を失っても面の記憶は残る）。
  func paneDidFocus(_ face: Face) {
    guard faces.focus != face else { return }
    setFaces(FaceLayout(editorRatio: faces.editorRatio, focus: face), animated: false)
  }

  /// ⌘⇧F。エディターを見せ（隠れていれば全面、見えていれば焦点だけ——`open_file` と同じ規則）、サイドバーを検索パネルで
  /// 開いて入力欄に焦点を入れる。種は押した時点の焦点で決めるので、配置を変える前に取る。
  func findInProject() {
    let pane = view.editor
    let seed = pane.projectSearchSeed()
    let ratio = faces.editorRatio == 0 ? 1 : faces.editorRatio
    setFaces(FaceLayout(editorRatio: ratio, focus: .editor), animated: true)
    pane.showProjectSearch(seed: seed)
  }

  /// 閉じれば失われる文書（未保存の列）。閉じる・終了の確認が読む。
  func unsavedDocuments() -> [EditorDocument] {
    MainActor.assumeIsolated { editor.documentsToDiscard() }
  }

  /// エディターでファイルを普通のタブで開いて焦点の文書にする（制御 API の入口。エージェントが見せたファイルを人の次の
  /// クリックが入れ替えない）。読めない・UTF-8 でない・テキスト面を作れない（Metal の装置が無い）は throw。
  func openFile(_ url: URL) throws {
    _ = try MainActor.assumeIsolated { try editor.open(url, as: .pinned) }
  }

  /// エディターで diff を普通のタブで開いて焦点にする（制御 API の入口。エージェントが人に変更を見せる）。テキスト面を
  /// 作れない（Metal の装置が無い）は throw。
  func openDiff(_ id: EditorDiff.Key) throws {
    _ = try MainActor.assumeIsolated { try editor.openDiff(id, as: .pinned) }
  }

  /// エディター面からのウィンドウレベル chrome キー（タブ・workspace）を上位へ転送する。
  func requestWindowCommand(_ command: WindowCommand) {
    onWindowCommand?(command)
  }

  /// 連の最後のタブが cd で別の根へ移り、行き先に連が無い。キーを書き換え、エディター面の根を付け替える。
  func rekey(_ key: String) {
    self.key = key
    view.editor.setRoot(key)
  }

  /// 連の最後のタブが cd で `other` から移ってきた。`other` のタブ（文書と diff）を自分の列の末尾へ引き取る
  /// （→ `EditorSession.adopt`）。本体の束縛（テキスト面の親・観測・一致の強調・diff の見せ方）は pane が 1 枚だけ持つので、
  /// 先に `other` の pane から離してから移す。
  /// `other` に復元待ちが残っていれば（一度も載らなかった）、自分が載っていれば開き、まだなら自分の復元待ちへ合わせる。
  func absorb(_ other: TabGroup) {
    MainActor.assumeIsolated {
      other.view.editor.releaseBody()
      editor.adopt(from: other.editor)
    }
    guard let pending = other.pendingDocuments.take() else { return }
    if materialized {
      MainActor.assumeIsolated {
        editor.restore(paths: pending.open, active: pending.active, preview: pending.preview)
      }
    } else {
      pendingDocuments = pendingDocuments?.merging(pending) ?? pending
    }
  }

  /// この連の永続状態。配置が既定で、文書も検索の問いも無ければ nil（書かない）。文書は開いているものに、未消費の復元状態
  /// を後ろに合わせたもの——まだ一度も載っていない連へ cd で文書が入っても、復元待ちの文書を書き落とさない。
  func groupState() -> GroupState? {
    let editorState: EditorState? = MainActor.assumeIsolated {
      let opened = openedDocuments()
      let open = pendingDocuments.map { opened?.merging($0) ?? $0 } ?? opened
      let state = EditorState(documents: open, search: view.editor.projectSearch.query)
      return state.isEmpty ? nil : state
    }
    guard faces != .terminalOnly || editorState != nil else { return nil }
    return GroupState(root: key, faces: faces, editor: editorState)
  }

  /// 開いている文書のタブ（diff のタブは戻さないので書かない）。焦点が diff のタブなら、diff のタブを除いた列でその位置に
  /// ある文書のタブ——右隣、無ければ左隣。焦点のタブを閉じたときに焦点が移る規則（`EditorSession.close`）と同じ。
  @MainActor
  private func openedDocuments() -> EditorState.OpenDocuments? {
    let tabs = editor.tabs
    let files = tabs.compactMap { tab -> EditorDocument? in
      if case .document(let document) = tab { return document }
      return nil
    }
    guard !files.isEmpty else { return nil }
    let index = tabs.firstIndex { $0.id == editor.activeID } ?? 0
    let before = tabs[..<index].filter { if case .document = $0 { true } else { false } }.count
    let active = editor.activeDocument ?? files[min(before, files.count - 1)]
    let preview = editor.previewID.flatMap { id -> String? in
      guard case .document(let url) = id else { return nil }
      return url.path
    }
    return EditorState.OpenDocuments(
      open: files.map(\.url.path), active: active.url.path, preview: preview)
  }
}
