import Foundation

/// ワークスペース作成フォームの状態機械（@Observable）。
/// ソース切替（既存フォルダ / git clone）を持ち、folder ではパス補完＋名前追従、clone では URL＋clone 先と
/// clone 実行（状態機械）を駆動する。描画は `WorkspaceCreateOverlay`。意味（追従/リンク解除/再リンク・導出名・
/// 作成可否・clone 実行状態）はここに集約し、View は写す。
@Observable final class WorkspaceCreateModel {
  /// 作成ソース。folder＝既存フォルダのパス / clone＝URL からリポジトリを clone。
  enum Source { case folder, clone }
  /// clone 実行の状態。running＝待機（キャンセル不可）／failed＝git stderr を inline 表示。
  enum CloneState { case idle, running, failed(String) }
  /// clone runner の型（url, 展開済み絶対 dest, completion）。completion(nil)＝成功 / completion(stderr)＝失敗
  /// （`GitRepo.addWorktree` と同契約・completion は main で呼ぶ）。closure 注入で実 git を単体テストから切る。
  typealias CloneRunner = (String, String, @escaping (String?) -> Void) -> Void

  /// アクティブなソース。切替で本文フォームが差し替わる。
  private(set) var source: Source = .folder
  /// パス欄（`~` 可・folder ソース）。編集のたびに補完を起こし、名前を追従へ戻す。
  var path: String
  /// リポジトリ URL（clone ソース）。初期値は空欄（placeholder で例を薄字表示）。編集で名前を追従へ戻す。
  private(set) var cloneURL: String = ""
  /// clone 先の親ディレクトリ（`~` 可・clone ソース）。初期値は folder の path と同じ導出。
  private(set) var cloneDir: String
  /// 名前欄の手入力値。nil＝ソースの導出名へ追従（linked）。手入力で非 nil（リンク解除）。folder/clone 共有。
  private(set) var name: String?
  /// clone 実行の状態機械。
  private(set) var cloneState: CloneState = .idle
  /// パス補完の候補（背景 queue の列挙結果を main で受ける）。
  var suggestions: [FolderSuggestion] = []
  /// 補完ドロップダウンのハイライト index。
  var highlighted = 0
  /// focus トリガ。提示元がインクリメントし、SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0

  /// 「作成して開く」。(rootPath, name) を渡す（`~` は store が展開）。folder は入力パス・clone は clone 先。
  var onCreate: (String, String) -> Void = { _, _ in }
  /// clone runner（既定は no-op＝配線/テストで注入）。
  var onClone: CloneRunner = { _, _, _ in }
  /// キャンセル / esc / scrim タップ（＝切替画面へ戻す）。
  var onDismiss: () -> Void = {}

  init(path: String) {
    self.path = path
    self.cloneDir = path  // clone 先の親も folder と同じ初期値（cwd 短縮 or `~`）
  }

  // MARK: - 派生

  /// 名前がソースの導出名へ追従中か。
  var linked: Bool { name == nil }
  /// パス末尾セグメントから導出した名前（folder・空なら "workspace"）。
  var derivedName: String {
    let last = ((path as NSString).expandingTildeInPath as NSString).lastPathComponent
    return last.isEmpty ? "workspace" : last
  }
  /// clone URL 末尾セグメントから `.git` を除いて導出した名前（空なら "workspace"）。
  /// scp-like（`git@host:owner/repo.git`）も `/` 分割で末尾 `repo` を取れる。空セグメントは畳むので
  /// 末尾スラッシュ（`.../repo/`）でも `repo` を取れる（folder 側 lastPathComponent と同挙動）。
  var cloneDerivedName: String {
    let trimmed = cloneURL.trimmingCharacters(in: .whitespaces)
    var last = String(trimmed.split(separator: "/").last ?? "")
    if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
    return last.isEmpty ? "workspace" : last
  }
  /// アクティブソースの導出名（folder=パス末尾 / clone=URL 末尾-.git）。
  var sourceDerivedName: String {
    switch source {
    case .folder: return derivedName
    case .clone: return cloneDerivedName
    }
  }
  /// 表示・作成に使う実効名。
  var curName: String { linked ? sourceDerivedName : (name ?? "") }
  /// clone 先 `clone先/名前`（`~` を保持・展開は submit で行う）。
  var cloneFinalDest: String {
    (cloneDir as NSString).appendingPathComponent(curName)
  }
  /// パスが実在するディレクトリか（folder の作成可否）。
  var pathExists: Bool { Self.isExistingDirectory(path) }
  /// clone 先の親（cloneDir）が実在ディレクトリか（clone の作成可否ガード）。
  var cloneParentExists: Bool { Self.isExistingDirectory(cloneDir) }
  /// clone 実行中か（待機表示・二重実行防止・esc/Scrim 無視の判定）。
  var isCloning: Bool {
    if case .running = cloneState { return true }
    return false
  }
  /// clone 失敗時の git stderr（inline 表示）。
  var cloneError: String? {
    if case .failed(let message) = cloneState { return message }
    return nil
  }
  /// 「作成して開く」可否。folder＝実在ディレクトリ＋非空名 / clone＝URL 非空＋親実在＋非空名。
  var canCreate: Bool {
    switch source {
    case .folder:
      return pathExists && !curName.trimmingCharacters(in: .whitespaces).isEmpty
    case .clone:
      return !cloneURL.trimmingCharacters(in: .whitespaces).isEmpty
        && cloneParentExists
        && !curName.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }

  private static func isExistingDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let expanded = (path as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
  }

  // MARK: - 操作

  func focus() { focusToken &+= 1 }

  /// ソース切替。入力（path/cloneURL/cloneDir）は保持し、名前だけ追従へ戻す（導出元が変わるため）。
  /// clone の試行状態も捨てる（`.failed` の inline エラーが folder タブへ持ち越らないよう `.idle` へ）。
  /// focusToken を進め、切替先ソースの主入力欄（folder=パス / clone=URL）へ focus を移す——SrcTab は
  /// ボタンで、切替で旧ソースの入力欄が unmount されるため、明示的に focus を張り直さないと「どの欄にも
  /// focus が無い」状態になり esc/↑↓/tab を拾う TextField が消える（表示中は常に入力欄 focus の不変）。
  func setSource(_ newValue: Source) {
    source = newValue
    name = nil  // アクティブソースが変わると導出元が変わる＝relink
    cloneState = .idle  // clone スコープの失敗表示をソース境界で捨てる
    focusToken &+= 1  // 切替先ソースの主入力欄へ focus を移す（View が次 tick で確定）
  }

  /// URL 編集（clone 入力欄バインドの setter から）。名前を追従へ戻す（URL 変更で導出名が変わる）。
  /// 同値の書き戻し（TextField が現在値を再送するケース）では relink しない＝手入力名を消さない
  /// （folder 側 `setPath` と同じ冪等契約）。
  func setCloneURL(_ newValue: String) {
    guard newValue != cloneURL else { return }
    cloneURL = newValue
    name = nil
  }

  /// clone 先編集（clone 入力欄バインドの setter から）。名前には無関係。
  func setCloneDir(_ newValue: String) {
    guard newValue != cloneDir else { return }
    cloneDir = newValue
  }

  /// パス編集（入力欄バインドの setter から）。名前を追従へ戻し、補完を背景 queue で起こす。
  func setPath(_ newValue: String) {
    guard newValue != path else { return }
    path = newValue
    name = nil  // パス変更で名前は追従へ戻す
    refreshSuggestions()
  }

  /// 名前手入力（入力欄バインドの setter から）。リンクを解除して手入力値を保持する。
  func setName(_ newValue: String) {
    name = newValue
  }

  /// 「再リンク」押下。名前をパス追従へ戻す。
  func relink() { name = nil }

  /// 補完ハイライトの移動（↑↓・巡回）。
  func moveHighlight(_ direction: Int) {
    guard !suggestions.isEmpty else { return }
    highlighted = (highlighted + direction + suggestions.count) % suggestions.count
  }

  /// 補完候補の先頭/末尾へハイライトをジャンプ（d<0=先頭・d>=0=末尾。空は no-op）。
  func jumpHighlight(_ d: Int) {
    guard !suggestions.isEmpty else { return }
    highlighted = d < 0 ? 0 : suggestions.count - 1
  }

  /// ⇥ 補完確定。ハイライト候補のフルパスへ差し替え、名前を追従へ戻し、ドロップダウンを閉じる。
  /// 候補が無ければ false（呼び出し側は名前欄へ focus を送る）。マウスで候補行をタップした確定でも
  /// パス欄へ focus を戻す（focusToken を進める）——表示中は常に入力欄が focus の不変を保つ。
  @discardableResult
  func acceptSuggestion() -> Bool {
    guard suggestions.indices.contains(highlighted) else { return false }
    path = (suggestions[highlighted].fullPath as NSString).abbreviatingWithTildeInPath
    name = nil
    highlighted = 0
    suggestions = []  // 確定でドロップダウンを閉じる（再度打鍵で開き直す）
    focusToken &+= 1  // パス欄へ focus を戻す（マウス確定で focus が抜けても入力欄へ復帰）
    return true
  }

  /// esc 補完キャンセル。候補ドロップダウンを閉じるだけ（パスは保持）。候補が無ければ false
  /// （呼び出し側は前の画面へ戻す）。`acceptSuggestion()` と対称に「閉じる」意味を model に集約する。
  @discardableResult
  func dismissSuggestions() -> Bool {
    guard !suggestions.isEmpty else { return false }
    suggestions = []
    highlighted = 0
    return true
  }

  /// ↵ 作成。folder＝そのまま onCreate。clone＝headless に clone を回し、成功で onCreate（clone 先）・
  /// 失敗で stderr を inline 表示。実行中は二重実行を防ぐ（`guard !isCloning`）。
  func submit() {
    guard canCreate else { return }
    switch source {
    case .folder:
      onCreate(path, curName)
    case .clone:
      guard !isCloning else { return }  // 実行中の再 submit は無視（Enter 連打の保険）
      cloneState = .running
      let finalDest = cloneFinalDest  // `~` 保持（onCreate へ・store が展開）
      let createdName = curName
      let expandedDest = (finalDest as NSString).expandingTildeInPath  // git へは展開済み絶対パス
      onClone(cloneURL.trimmingCharacters(in: .whitespaces), expandedDest) { [weak self] stderr in
        guard let self else { return }
        if let stderr {
          self.cloneState = .failed(stderr)
        } else {
          self.cloneState = .idle
          self.onCreate(finalDest, createdName)
        }
      }
    }
  }

  /// パス変更のたびに補完を背景 queue で列挙し main で受ける（投機結果は stale 破棄）。
  private func refreshSuggestions() {
    let requested = path
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = FolderSuggestions.compute(input: requested)
      DispatchQueue.main.async {
        guard let self, self.path == requested else { return }  // stale 破棄
        self.suggestions = result
        if self.highlighted >= result.count { self.highlighted = 0 }
      }
    }
  }
}
