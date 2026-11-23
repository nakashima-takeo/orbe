import Foundation

/// Files の一覧の行の組——見出しの行（「開いているファイル N」と ⌘P）と、開いている文書の列（最近使った順）の写し。行 0 が
/// 見出し、行 i + 1 が文書 i。同一性は文書の実体の URL。
struct OpenFilesRows: EditorItemListRows {
  let heading: EditorItemListRow
  let files: [EditorItemListRow.File]
  let urls: [URL]
  private let indices: [URL: Int]

  init(heading: EditorItemListRow, files: [EditorItemListRow.File], urls: [URL]) {
    self.heading = heading
    self.files = files
    self.urls = urls
    indices = Dictionary(urls.enumerated().map { ($1, $0) }) { first, _ in first }
  }

  var count: Int { files.count + 1 }

  func row(at index: Int) -> EditorItemListRow { index == 0 ? heading : .file(files[index - 1]) }

  func id(at index: Int) -> AnyHashable? { index == 0 ? nil : urls[index - 1] }

  func index(of id: AnyHashable) -> Int? {
    (id.base as? URL).flatMap { indices[$0] }.map { $0 + 1 }
  }
}

/// Files の一覧の詳細の行の組——先頭にその文書のファイルの行（選べない）、続けて操作の行。
struct OpenFileDetailRows: EditorItemListRows {
  let file: EditorItemListRow.File
  let actions: [(id: OpenFileAction, title: String)]

  var count: Int { actions.count + 1 }

  func row(at index: Int) -> EditorItemListRow {
    index == 0 ? .file(file) : .action(actions[index - 1].title)
  }

  func id(at index: Int) -> AnyHashable? { index == 0 ? nil : actions[index - 1].id }

  func index(of id: AnyHashable) -> Int? {
    actions.firstIndex { $0.id == id.base as? OpenFileAction }.map { $0 + 1 }
  }
}

/// Files の一覧の詳細の操作。
enum OpenFileAction: Hashable {
  case keepOpen(URL)
  case close(URL)
}

/// Files の一覧を一覧の器に載せる側。中身は pane がセッションから作り、行を決めた・× を押したときは pane の今ある操作を呼ぶ。
@MainActor
final class OpenFilesList: EditorItemListOwner {
  private unowned let pane: EditorPaneView

  init(pane: EditorPaneView) {
    self.pane = pane
  }

  func itemListContent() -> EditorItemListContent { pane.openFilesContent() }

  func itemListDetail(of id: AnyHashable) -> EditorItemListContent? {
    (id.base as? URL).flatMap(pane.openFileDetail)
  }

  /// 文書の行は、その文書を今の文書にして本文へフォーカスを移す（仮の文書は仮のまま）。詳細の操作は一覧へ戻る——
  /// 未保存の文書を閉じる確認の間も、器は一覧へ戻っている。
  func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome {
    if let url = id.base as? URL {
      pane.activate(url)
      return .close
    }
    switch id.base as? OpenFileAction {
    case .keepOpen(let url): pane.group?.editor.pin(url)
    case .close(let url): pane.requestClose(url)
    case nil: return .stay
    }
    return .back
  }

  /// 行の × は文書を閉じ（未保存なら確認が出る）、一覧は開いたまま。
  func itemListPress(_ id: AnyHashable) {
    if let url = id.base as? URL { pane.requestClose(url) }
  }
}
