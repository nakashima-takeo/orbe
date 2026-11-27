import Foundation
import OrbeEditorCore

/// ツリーの絞り込み——ツリーに掛ける一時の見え方。字（空でなければ絞り込み中）と、届いた結果と、絞り込みの間だけの開閉を
/// 持ち、対象の一覧（`RootFiles.listFilterPaths`）の取り直しの段取りと、照合・木の組み立てを裏で行う。ツリーが 1 つ持つ。
/// 絞り込んでいないツリーの開閉・一覧・選択は、絞り込みの間も裏でそのまま生きている。
///
/// 照合と組み立ては裏の直列キュー 1 本で行い、走っている間に字が変わったら、終わった後にいちばん新しい字で 1 回だけ走らせ
/// 直す。
/// 新しい字の結果が届くまでは、前の結果を出したままにする（打つたびにツリーがちらつかない）。
@MainActor @Observable
final class FileTreeFilter {
  /// 照合と組み立ての結果（ツリーの一覧と同じ形）。
  struct Result: Equatable, Sendable {
    /// どの字の結果か。
    let text: String
    /// フォルダ（根からの相対。根は空）→ 子の列（フォルダが先・名前順）。
    let children: [String: [RootFiles.Entry]]
    /// フォルダ → ただ 1 つの子フォルダの名前（連なりをまとめるため）。
    let onlyChild: [String: String]
    /// 合ったファイルの数（上限で打ち切れば上限）。
    let matchCount: Int
    /// 合ったファイルが上限に達して打ち切った。
    let matchesTruncated: Bool
    /// 対象の一覧そのものが上限で打ち切られていた。
    let listTruncated: Bool
  }

  /// 照合のインデックス（対象の一覧と、正規化して小文字にそろえた名前）。
  struct Index: Sendable {
    let root: URL
    let paths: [String]
    let names: [[UInt8]]
    let isTruncated: Bool
  }

  /// 合ったファイルとして出す上限。
  static let matchLimit = 10_000
  /// 結果を待っている表示を出すまでの間（秒）。
  static let waitDelay: TimeInterval = 0.3

  /// 字（空なら絞り込んでいない）。
  private(set) var text = ""
  /// 届いた結果（今の字の結果とは限らない）。
  private(set) var result: Result?
  /// 絞り込みの間に畳んだフォルダ（連なりのいちばん深いフォルダ）。字が変わると空になる。
  private(set) var collapsed: Set<String> = []
  /// 結果を 0.3 秒より長く待っている。
  private(set) var isWaiting = false
  /// 対象の一覧を取れずにいる（前に取れた一覧も無い）。
  private(set) var listFailed = false
  /// 一覧が古い（まだ取っていない・取った後に通知が来た・面が見えていなかった）。
  @ObservationIgnored private(set) var isStale = true

  @ObservationIgnored private let root: URL
  @ObservationIgnored private let queue = DispatchQueue(
    label: "orbe.file-tree.filter", qos: .userInitiated)
  @ObservationIgnored private var index: Index?
  @ObservationIgnored private var isListing = false
  @ObservationIgnored private var listAgain = false
  /// 一覧を捨てるたびに進む番号。捨てる前に頼んだ取得の結果（一覧も失敗も）を受け取らないため。
  @ObservationIgnored private var listGeneration = 0
  @ObservationIgnored private var isMatching = false
  /// 照合が走っている間に変わった、いちばん新しい字。
  @ObservationIgnored private var pendingText: String?
  @ObservationIgnored let waitDelay = EditorDelay()

  init(root: String) {
    self.root = URL(fileURLWithPath: root, isDirectory: true)
  }

  /// 絞り込み中（字が空でない）。字とは別に持ち、空かどうかが替わったときだけ書く——ツリーの行と一覧のスクロールを、打鍵の
  /// たびではなく、絞り込みの出入りと結果の替わりでだけ組み直すため。
  private(set) var isActive = false

  /// 行に出す結果（絞り込み中で、結果が届いていれば）。
  var shown: Result? { isActive ? result : nil }

  // MARK: - 字と開閉

  /// 字を置き換える。空になればすぐ絞り込みを解く。空でなければ、絞り込みの間の開閉を捨て、一覧が古ければ `files` から
  /// 取り直し（`files` が無ければ取り直さない）、裏で照合する。
  func setText(_ next: String, files: RootFiles?) {
    guard next != text else { return }
    text = next
    if isActive == next.isEmpty { isActive = !next.isEmpty }
    if !collapsed.isEmpty { collapsed = [] }
    waitDelay.cancel()
    guard !next.isEmpty else {
      result = nil
      isWaiting = false
      return
    }
    if isStale, let files { relist(files) }
    match(next)
    waitDelay.run(after: Self.waitDelay) { [weak self] in
      guard let self, isActive, result?.text != text, !listFailed else { return }
      isWaiting = true
    }
  }

  /// 連なりの先頭 `head` のフォルダの行を開閉する（選択は動かさない）。
  func toggle(_ head: String) {
    guard let result = shown else { return }
    var deepest = head
    while let child = result.onlyChild[deepest] { deepest += "/" + child }
    if collapsed.contains(deepest) {
      collapsed.remove(deepest)
    } else {
      collapsed.insert(deepest)
    }
  }

  /// 結果のフォルダを全部畳む。
  func collapseAll() {
    guard let result = shown else { return }
    collapsed = Set(result.children.keys.filter { !$0.isEmpty })
  }

  // MARK: - 対象の一覧

  /// 一覧が古いというフラグを立てる。
  func markStale() {
    isStale = true
  }

  /// 一覧と「取れずにいる」フラグを捨てる。取得中の一覧は、届いても受け取らない。
  func discardList() {
    listGeneration += 1
    listAgain = false
    index = nil
    isStale = true
    if listFailed { listFailed = false }
  }

  /// 一覧を取り直す（走っていれば「終わったらもう 1 回」）。取れたら今の字で照合し直す。取れなければ前の一覧を保ち、前の
  /// 一覧も無ければ「取れずにいる」を立てる（次のきっかけでもう一度取る）。頼んだ後に一覧が捨てられていれば、結果は受け取らない
  /// （捨てた後に頼まれた「もう 1 回」は走らせる）。git 管理下かの判定の前なら「古い」フラグだけを立てる——ツリーは判定が済んだ
  /// 知らせで取り直しを頼み直す。
  func relist(_ files: RootFiles) {
    guard files.isResolved else { return markStale() }
    isStale = false
    guard !isListing else {
      listAgain = true
      return
    }
    isListing = true
    let generation = listGeneration
    files.listFilterPaths { [weak self, weak files] list in
      guard let self else { return }
      isListing = false
      if generation == listGeneration { take(list, generation: generation) }
      if listAgain, let files {
        listAgain = false
        relist(files)
      }
    }
  }

  /// 世代 `generation` の取得の結果を受け取る。一覧ならインデックスを裏で作り、作り終えたときも一覧が捨てられていなければ
  /// 差し替える。
  private func take(_ list: RootFiles.PathList, generation: Int) {
    switch list {
    case .listed(let paths, let isTruncated):
      let root = self.root
      queue.async {
        let index = Self.index(root: root, paths: paths, isTruncated: isTruncated)
        DispatchQueue.main.async { [weak self] in
          guard let self, generation == listGeneration else { return }
          adopt(index)
        }
      }
    case .failed:
      isStale = true
      if index == nil {
        listFailed = true
        isWaiting = false
      }
    }
  }

  /// 取れた一覧のインデックスに差し替え、今の字で照合し直す。
  func adopt(_ index: Index) {
    self.index = index
    if listFailed { listFailed = false }
    match(text)
  }

  // MARK: - 照合

  /// `text`（空でない）で照合する。インデックスが無ければ何もしない（届いたときに照合する）。
  private func match(_ text: String) {
    guard !text.isEmpty, let index else { return }
    guard !isMatching else {
      pendingText = text
      return
    }
    isMatching = true
    queue.async {
      let result = Self.result(of: index, text: text)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        isMatching = false
        receive(result)
        if let next = pendingText {
          pendingText = nil
          match(next)
        }
      }
    }
  }

  /// 届いた結果。今の字の結果であるときだけ受け取り、前と同じなら書かない。
  func receive(_ next: Result) {
    guard next.text == text else { return }
    waitDelay.cancel()
    if isWaiting { isWaiting = false }
    if next != result { result = next }
  }

  /// 照合の正規化（合成済みの形と小文字）。名前と打った字の両方に当てる。
  nonisolated static func fold(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// 照合のインデックスを作る（名前を正規化して小文字にそろえる。裏で 1 度だけ）。
  nonisolated static func index(root: URL, paths: [String], isTruncated: Bool) -> Index {
    let names = paths.map { path in
      let name = path.split(separator: "/").last.map(String.init) ?? path
      return Array(fold(name).utf8)
    }
    return Index(root: root, paths: paths, names: names, isTruncated: isTruncated)
  }

  /// 名前に字を含むパスを一覧の順に上限まで集め、フォルダの木を作る（裏で呼ぶ）。
  nonisolated static func result(of index: Index, text: String) -> Result {
    let query = Array(fold(text).utf8)
    var matched: [String] = []
    var truncated = false
    for (offset, name) in index.names.enumerated() where contains(name, query) {
      if matched.count == matchLimit {
        truncated = true
        break
      }
      matched.append(index.paths[offset])
    }
    var files: [String: [String]] = [:]
    var folders: [String: Set<String>] = [:]
    for path in matched {
      var parent = ""
      let components = path.split(separator: "/").map(String.init)
      for component in components.dropLast() {
        folders[parent, default: []].insert(component)
        parent = parent.isEmpty ? component : parent + "/" + component
      }
      files[parent, default: []].append(components.last ?? path)
    }
    var children: [String: [RootFiles.Entry]] = [:]
    var onlyChild: [String: String] = [:]
    for folder in Set(files.keys).union(folders.keys) {
      let base = folder.isEmpty ? index.root : index.root.appendingPathComponent(folder)
      let subfolders = (folders[folder] ?? []).sorted(by: FileNameOrder.precedes)
      let names = (files[folder] ?? []).sorted(by: FileNameOrder.precedes)
      children[folder] =
        subfolders.map {
          RootFiles.Entry(
            name: $0, url: base.appendingPathComponent($0, isDirectory: true), isDirectory: true)
        }
        + names.map {
          RootFiles.Entry(
            name: $0, url: base.appendingPathComponent($0, isDirectory: false), isDirectory: false)
        }
      if names.isEmpty, subfolders.count == 1 { onlyChild[folder] = subfolders[0] }
    }
    return Result(
      text: text, children: children, onlyChild: onlyChild, matchCount: matched.count,
      matchesTruncated: truncated, listTruncated: index.isTruncated)
  }

  /// `name` が `query` をバイトの並びとして含むか。
  private nonisolated static func contains(_ name: [UInt8], _ query: [UInt8]) -> Bool {
    guard let first = query.first else { return true }
    guard query.count <= name.count else { return false }
    var start = 0
    let last = name.count - query.count
    while start <= last {
      if name[start] == first {
        var offset = 1
        while offset < query.count, name[start + offset] == query[offset] { offset += 1 }
        if offset == query.count { return true }
      }
      start += 1
    }
    return false
  }
}
