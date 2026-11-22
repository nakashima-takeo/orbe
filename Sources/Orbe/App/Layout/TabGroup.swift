import AppKit
import OrbeEditorCore

/// workspace の中の連（同じ worktree のタブの並び）1 本に 1 つ。連のタブが共有するもの——エディターのセッション・
/// 器（`GroupFacesView`）・開いていた文書の復元待ち——を持つ。連の中でタブを切り替えると、器の中の端末だけが入れ替わる。
///
/// 寿命は、それを所属に持つタブが居る間だけ。作る・付け替える・畳むのは `WindowController` だけで、キー K の連は
/// 「キー K のタブの所属」で引く（表は持たない）。器は AppKit の NSView のまま作り直さない（cf. `TerminalTab`）。
final class TabGroup {
  /// 連のキー＝worktree ルート（管理外は cwd 自身の正規形パス）。エディター面の根も同じ値。書くのは `rekey` だけ。
  private(set) var key: String
  /// エディターのセッション。書き手は連とその pane で、外（制御 API）は `openFile`・`openDiff` を通る。エディターの型は
  /// UI に閉じた `@MainActor` で、連はその外（main スレッド規律の nonisolated）にいるため、触る箇所は
  /// `MainActor.assumeIsolated` で境を越える。
  let editor: EditorSession
  /// mount 単位（端末面とエディター面の器）。`WindowController` の照合が content へ載せる／隠す／外す。
  let view: GroupFacesView
  /// 未消費の復元状態（開いていた文書）。器が初めて content に載るとき（`materialize`）に消費する。一度も載らなければ
  /// 同じ形で書き戻す。
  private var pendingDocuments: EditorState.OpenDocuments?
  /// 器が一度でも content に載ったか。
  private var materialized = false

  /// 画面・タブの列・焦点のタブ・未保存の有無・検索の問いが変わった（chrome 更新・永続保存は上位）。
  var onEditorChange: (() -> Void)?
  /// エディター面からのウィンドウレベルの chrome キーを上位へ届ける。
  var onWindowCommand: ((WindowCommand) -> Void)?

  /// `state` は復元した連のエディターの状態（開いていた文書・選んでいた画面・検索の問い）。
  init(key: String, state: EditorState? = nil, editorSurfaces: EditorSurfaces = .shared) {
    self.key = key
    editor = MainActor.assumeIsolated {
      EditorSession(
        surfaces: editorSurfaces, defaultScreen: Self.defaultScreen(of: key),
        chosenScreen: state?.screen)
    }
    view = GroupFacesView(editor: EditorPaneView(root: key))
    pendingDocuments = state?.documents
    wireView()
    if let search = state?.search {
      MainActor.assumeIsolated { view.editor.projectSearch.restore(search) }
    }
  }

  /// 画面を選ぶまでの画面——根が git の worktree の根なら Changes、そうでなければ Files（連のキーを決めるのと同じ規則）。
  private static func defaultScreen(of key: String) -> EditorScreen {
    GitWorktreeRoot.locate(cwd: key) == key ? .changes : .files
  }

  /// pane が連を知るよう配線する。セッションの変化は器（面の骨と中身）へ写してから上位へ 1 本で上げる。
  private func wireView() {
    view.editor.group = self
    MainActor.assumeIsolated {
      view.editor.sessionDidChange()
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

  /// 連の最後のタブが cd で別の根へ移り、行き先に連が無い。キーを書き換え、エディター面の根を付け替え、画面を選ぶまでの
  /// 画面を新しい根で決め直す。
  func rekey(_ key: String) {
    self.key = key
    view.editor.setRoot(key)
    MainActor.assumeIsolated { editor.rootDidChange(defaultScreen: Self.defaultScreen(of: key)) }
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

  /// この連の永続状態。文書も選んだ画面も検索の問いも無ければ nil（書かない）。文書は開いているものに、未消費の復元状態
  /// を後ろに合わせたもの——まだ一度も載っていない連へ cd で文書が入っても、復元待ちの文書を書き落とさない。
  func groupState() -> GroupState? {
    let state: EditorState = MainActor.assumeIsolated {
      let opened = openedDocuments()
      let open = pendingDocuments.map { opened?.merging($0) ?? $0 } ?? opened
      return EditorState(
        documents: open, screen: editor.chosenScreen, search: view.editor.projectSearch.query)
    }
    guard !state.isEmpty else { return nil }
    return GroupState(root: key, editor: state)
  }

  /// エディターで見せているときの、chrome の現在地。根の下のファイル（文書のタブ・作業ツリーとステージ済みの diff のタブ）は
  /// 根と相対パス、PR の diff のタブは PR の番号と相対パス、根の外のファイルは絶対パス、タブが無ければ根だけ。
  var editorLocation: TerminalTab.Location {
    let root = key
    return MainActor.assumeIsolated {
      guard let tab = editor.activeTab else { return .root(root) }
      if case .diff(let diff) = tab, case .pullRequest(let state) = diff.id.kind {
        return .pullRequest(number: state.key.id.number, relative: diff.id.path)
      }
      let path = tab.url.path
      guard path.hasPrefix(root + "/") else { return .absolute(path) }
      return .file(root: root, relative: String(path.dropFirst(root.count + 1)))
    }
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
