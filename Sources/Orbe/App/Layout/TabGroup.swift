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

  /// 画面・開いている文書・今の文書・diff・未保存の有無・検索の問いが変わった（chrome 更新・永続保存は上位）。
  var onEditorChange: (() -> Void)?
  /// エディター面からのウィンドウレベルの chrome キーを上位へ届ける。
  var onWindowCommand: ((WindowCommand) -> Void)?
  /// エディターで見せているときの現在地が変わったかもしれない（worktree の今の PR の答えが替わった。chrome 更新は上位）。
  var onLocationChange: (() -> Void)?

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
      view.editor.onPullRequestChange = { [weak self] in self?.onLocationChange?() }
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

  /// エディターでファイルを普通の文書として開いて今の文書にし、Files の画面を選ぶ（制御 API の入口。エージェントが見せた
  /// ファイルを人の次のクリックが入れ替えない）。読めない・UTF-8 でない・テキスト面を作れない（Metal の装置が無い）は
  /// throw し、画面を選ばない。
  func openFile(_ url: URL) throws {
    try MainActor.assumeIsolated {
      try editor.open(url, as: .pinned)
      editor.selectScreen(.files)
    }
  }

  /// エディターで diff を Changes の diff として開き、Changes の画面を選び、左の列でその行を選択表示する（制御 API の入口。
  /// エージェントが人に変更を見せる。人が左の列で別の行を選べば入れ替わる）。テキスト面を作れない（Metal の装置が無い）は
  /// throw し、画面を選ばない。
  func openDiff(_ id: EditorDiff.Key) throws {
    try MainActor.assumeIsolated {
      try view.editor.openDiff(id)
      editor.selectScreen(id.kind.screen)
    }
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

  /// 連の最後のタブが cd で `other` から移ってきた。`other` の開いている文書を自分の列の末尾へ引き取り、`other` の diff は
  /// 手放させる（→ `EditorSession.adopt`）。本体の束縛（テキスト面の親・観測・一致の強調・diff の見せ方）は pane が 1 枚だけ持つので、
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

  /// エディターで見せているときの、chrome の現在地。画面から導く——Files は今の文書（根の下なら根と相対パス、根の外なら
  /// 絶対パス、文書が無ければ根だけ）、Changes は根だけ、PR は worktree の今の PR の番号と根（PR が分からなければ根だけ）。
  var editorLocation: TerminalTab.Location {
    let root = key
    return MainActor.assumeIsolated {
      switch editor.screen {
      case .changes: return .root(root)
      case .pullRequest:
        guard let state = view.editor.pullRequest.state else { return .root(root) }
        return .pullRequest(number: state.key.id.number, root: root)
      case .files:
        guard let path = editor.activeDocument?.url.path else { return .root(root) }
        guard path.hasPrefix(root + "/") else { return .absolute(path) }
        return .file(root: root, relative: String(path.dropFirst(root.count + 1)))
      }
    }
  }

  /// 開いている文書の列と、今の文書と仮の文書。
  @MainActor
  private func openedDocuments() -> EditorState.OpenDocuments? {
    guard let active = editor.activeDocument else { return nil }
    return EditorState.OpenDocuments(
      open: editor.documents.map(\.url.path), active: active.url.path,
      preview: editor.previewURL?.path)
  }
}
