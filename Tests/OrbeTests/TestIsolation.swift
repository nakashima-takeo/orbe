import AppKit
import OrbePaths
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 全テストクラスの基底。隔離ハーネスへ点火し、テスト 1 件を画面と前面の隔離（`ScreenIsolation`）で包み、足場から
/// 預かったウィンドウをテスト 1 件の終わりまで持つ。
///
/// 点火は `class func setUp()`（クラス単位・全インスタンス setUp より前）で行う。最初に走った
/// 1 クラスが `TestIsolation.installOnce()` を呼び、そこでテストの境界へ登録される口が以降の全テスト
/// （この基底を継承しないクラスも含む）へ効く。だから継承は「どのクラスが最初に走っても点火される」
/// ことだけを担保すればよく、実環境の向け直しは基底に依存しない。画面と前面の隔離だけは、破ったテストに
/// 失敗を記録するのにそのテストのインスタンス（`XCTestCase`）が要るので、この基底を継承したクラスにだけ効く。
///
/// これが外れると、`swift test` が開発者の実 `workspaces.json`・ghostty の user 設定・
/// 実 state dir を読み書きし始め、実スピーカーを鳴らす。テストが手元の環境に依存して緑になり、
/// CI で落ちる。
class OrbeTestCase: XCTestCase {
  /// `static`（＝上書き不可）にするのは、サブクラスが `super` 抜きで上書きすると点火が外れるため。
  /// 上書きしようとした時点でコンパイルが落ちる＝実行時に無言で外れる経路が残らない。
  override static func setUp() {
    TestIsolation.installOnce()
    super.setUp()
  }

  /// true にするのは、画面に出して人が見る・計測する道具（環境変数で有効にするもの）だけ。true のクラスは、画面と前面の
  /// 隔離の対象から外れる。通常のテストがこれを上書きすると、lint が落とす。
  class var presentsOnScreen: Bool { false }

  private var heldWindows: [NSWindow] = []

  /// ビューを載せるために足場が作ったウィンドウを、テスト 1 件の終わり（画面と前面の隔離の確認の後）まで持つ。渡された
  /// ウィンドウをそのまま返す。
  @discardableResult
  func holdUntilTestEnds<Window: NSWindow>(_ window: Window) -> Window {
    heldWindows.append(window)
    return window
  }

  /// テスト 1 件（`setUp`・本文・`tearDown`）を、画面と前面の隔離で包み、最後に預かったウィンドウを手放す。失敗の記録は
  /// `tearDown` の後で、テストが終わったと記録される前に行う（テストの境界のフック（`TestScratch.addCaseHooks`）から
  /// 記録すると、テストは既に終わっていて落とせない）。手放すのが確認の後なのは、預かったウィンドウが画面に出ていれば
  /// 確認が見つけるため。XCTest はテストのインスタンスを実行の終わりまで持つので、ここで手放さないとウィンドウが残る。
  /// `final` にするのは、サブクラスが `super` 抜きで上書きすると隔離が外れるため。
  final override func invokeTest() {
    defer { heldWindows.removeAll() }
    guard !Self.presentsOnScreen else { return super.invokeTest() }
    let screen = MainActor.assumeIsolated { () -> ScreenIsolation in ScreenIsolation() }
    super.invokeTest()
    MainActor.assumeIsolated {
      screen.finish { breach in
        self.record(XCTIssue(type: .assertionFailure, compactDescription: breach))
      }
    }
  }
}

/// ハーネスが配る隔離済みの永続ファイル。arrange が実ファイルを置く先であり、
/// 各テストが自分でパスを組み立てないための唯一の出所。
extension OrbeTestCase {
  func workspacesFile() throws -> URL { try XCTUnwrap(WorkspacePersistence.fileURL) }
  func settingsFile() throws -> URL { try XCTUnwrap(SettingsPersistence.fileURL) }
  func appStateFile() throws -> URL { try XCTUnwrap(AppStatePersistence.fileURL) }
  func guiConfFile() throws -> URL { try XCTUnwrap(GuiConfig.fileURL) }
  func tasksFile() throws -> URL { try XCTUnwrap(TaskPersistence.fileURL) }
  func automationsFolder() throws -> URL { try XCTUnwrap(AutomationPersistence.folder) }
  func browserFolder() throws -> URL { try XCTUnwrap(BrowserPersistence.folder) }
}

/// テストプロセス全体の隔離。`installOnce()` は冪等で、最初の 1 回だけ実際に張る。
///
/// 作業ディレクトリとテストの境界は `TestScratch` が持ち、ここは Orbe の seam をその下へ向ける口を
/// 境界に登録するだけ。
///
/// 張る順序に意味がある。`ORBE_STATE_DIR` は `ControlServer.shared` の `private init()` が
/// 読むため、どのテスト本体よりも前に置かないと実 state dir の `control.sock` を掴む。
/// 掴んだかどうかは最後の assert が検査する（静かに実環境へ落ちさせない）。
///
/// 実環境を汚さないことの実証は `scripts/verify-test-isolation.sh`（手動・CI 非搭載）。
enum TestIsolation {
  /// Orbe の state dir（`control.sock` の置き場・子プロセスの `ORBE_STATE_DIR`）。`TestScratch.root` そのもの。
  private(set) nonisolated(unsafe) static var stateDir: URL!

  /// AF_UNIX の `sun_path` 上限は 104 バイト。`<stateDir>/control.sock` を足しても収まるよう、
  /// stateDir 自体をこの長さで抑える（超える環境では無言で制御 API が無効化するので落とす）。
  static let maxRootPathBytes = 90

  private nonisolated(unsafe) static var installed = false

  static func installOnce() {
    guard !installed else { return }
    installed = true

    // 1. 隔離根。
    let dir = TestScratch.root
    precondition(
      dir.path.utf8.count <= maxRootPathBytes,
      "隔離根が長すぎる（\(dir.path.utf8.count) > \(maxRootPathBytes)）: \(dir.path)")
    stateDir = dir

    // 2. state dir（本番と同じ ORBE_STATE_DIR 経路）。永続ファイルは下の `beginCase` が caseDir へ
    //    張り直すので、この根の直下に出るのは `c<連番>` の caseDir 群と、パス長のために直下へ
    //    置かざるを得ない AF_UNIX socket（`control.sock` / `OrbeReportWireTests` の `r.sock`）と
    //    補完の学習ストアと、テストをまたぐ fixture（`GitFixtureTemplate` のテンプレート）だけ。
    //    子プロセス（`ControlProcess.childEnv`）へ渡すのもこの根で、in-process 側の caseDir とは違う。
    setenv(OrbePaths.stateDirEnvVar, dir.path, 1)
    // git は開発者の global / system 設定（署名・hook・除外・fsmonitor 等）を読まない。`GitRunner` は
    // プロセスの環境を土台にするので、`git init` を含む全 fixture の全呼び出しに効く。
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
    // 開発者が launchd に配った GUI の askpass は、`GitRunner` がそのまま使う（対話の封じの例外）。テストの git に
    // ダイアログを出させず、封じの結果を手元の環境に依らせない。
    unsetenv("SSH_ASKPASS")
    // 開発者の `GIT_EDITOR`（`true` 等のすぐ返るもの）を残すと、エディタの封じが外れてもテストの git が待たずに返り、
    // 封じのテストが手元で落ちない。
    unsetenv("GIT_EDITOR")
    // gh の資格情報を渡す環境変数。残すと、PATH に本物の gh が入ったテストが開発者のトークンで GitHub へ届く。
    // 設定ディレクトリ（`GH_CONFIG_DIR`）は `beginCase` が空のディレクトリへ向ける。
    for key in [
      "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST",
    ] {
      unsetenv(key)
    }
    // ghostty のリソース根（theme の探索先）。libghostty は `ghostty_init` で 1 度だけ読むので、どの
    // テスト本体よりも前に張る。張らないと Orbe / Ghostty の端末から起動した `swift test` は親の
    // インストール済み .app を読み、CI と違う結果になる。`app/` は .app の `Resources/ghostty` と同じ
    // `themes/OrbeDark`・`OrbeLight` を持つ。
    let appResources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("app", isDirectory: true)
    setenv("GHOSTTY_RESOURCES_DIR", appResources.path, 1)

    // 3. 補完の学習ストア。`CompletionLearning.shared` は初回タッチ時の `fileURL` で in-memory
    //    ストアを焼くため、まだ誰も書いていないこの時点で固定して即タッチする。
    //    ＝この 1 種だけは per-test にできず、学習状態はテスト間で持ち越される。
    CompletionLearning.fileURLOverride = dir.appendingPathComponent("completion-learning.json")
    _ = CompletionLearning.shared

    // 4. `ControlServer.shared` が 2 より前に構築されていたら実 state dir の socket を掴んでいる。
    //    プロセス級の不変条件が壊れた状態で続けても以降の全テストが無意味なので落とす。
    let expected = dir.appendingPathComponent("control.sock").path
    let actual = ControlServer.shared.socketPath
    guard actual == expected else {
      fatalError(
        "ControlServer が隔離前に構築された（socketPath=\(actual) 期待=\(expected)）。"
          + "テスト本体より前に ORBE_STATE_DIR を張れていない")
    }

    // 5. ポインタの非表示。SwiftUI は、ホバーを決め直すたびに AppKit のポインタの非表示（`+[NSCursor _isHidden]`）を読み、
    //    非表示ならホバーを受け付けない。この値は利用者の実際の状態で、利用者がほかのアプリで打鍵してポインタが非表示に
    //    なっているあいだは、テストが送ったホバーが効かない。テストの中では、非表示ではないと返させる。
    CursorVisibility.pinShown()

    // 6. 毎テストの隔離。以降の全テストへ効く。
    TestScratch.addCaseHooks(begin: beginCase, end: endCase)
  }

  /// テスト 1 件の作業ディレクトリ（`TestScratch.caseDir`）の下へ、隔離の seam を向け直す。
  ///
  /// 値の素性（永続ファイル・Home のフォルダ・同梱リソース根・プラグイン実体化先・ghostty user 層・通知音の再生層・
  /// 端末のクリップボード・ゴミ箱）に関わらず **毎テスト無条件に張り直す**。テストが自分で書き換えても
  /// 次のテストへ漏れず、戻し忘れが起きえない——申告制を残さないため。`CompletionLearning` だけは `shared` が in-memory へ
  /// 焼き付ける都合で per-test にできず、`installOnce` の固定のままにする。
  ///
  /// **書き込まれうる先は caseDir の下へ置く。** 根の直下に置くとテスト終了の削除に乗らず、
  /// テストが書いた中身が以降の全テストへ残る（向き先だけ張り直しても中身は消えない）。
  /// 例外は AF_UNIX の listener——`sun_path` の 104 バイト上限に対し caseDir は `c<連番>` ぶん深く、
  /// 連番が伸びると bind が黙って落ちる。`TestScratch.root` 直下へ置き、自分で `unlink` して後始末する
  /// （`OrbeReportWireTests` がその形）。
  static func beginCase() {
    let dir = TestScratch.caseDir

    WorkspacePersistence.fileURLOverride = dir.appendingPathComponent("workspaces.json")
    SettingsPersistence.fileURLOverride = dir.appendingPathComponent("settings.json")
    AppStatePersistence.fileURLOverride = dir.appendingPathComponent("app-state.json")
    GuiConfig.fileURLOverride = dir.appendingPathComponent("gui.conf")
    AgentSessionLog.fileURLOverride = dir.appendingPathComponent("agent-sessions.jsonl")
    TaskPersistence.fileURLOverride = dir.appendingPathComponent("tasks.json")
    AutomationPersistence.folderOverride = dir.appendingPathComponent(
      "automations", isDirectory: true)
    BrowserPersistence.folderOverride = dir.appendingPathComponent("browser", isDirectory: true)

    // 同梱リソースの探索根。既定は Xcode の bin を指しており空でも中立でもないため、管理下の
    // 空ディレクトリを用意する（層1 の `orbe-defaults.conf` は不在になる）。テストが同梱物を
    // 組む先でもあるので caseDir の下に置く。
    let resources = dir.appendingPathComponent("resources", isDirectory: true)
    try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    BundledResources.root = resources

    // プラグインの実体化先。既定は `ORBE_STATE_DIR` 直下＝テスト間で共有される根なので、
    // 張らないと `WindowController()` の起動同期が書いた中身が次のテストへ残る。
    AgentPluginInstaller.stablePluginDirOverride =
      dir.appendingPathComponent("agent-plugin", isDirectory: true)

    // ghostty の user 層。ファイルは作らない＝不在なので読まれない。テストが層を立てるときは
    // ここへ書くので、他と同じく caseDir の下に置く（書いた中身がテスト終了の削除に乗る）。
    Config.userFileURLOverride = dir.appendingPathComponent("ghostty-user.conf")

    // 通知音の再生層。スピーカーは実 state dir と同じく管理外の実環境なので、記録だけするフェイクへ
    // 向ける（`WindowController` を立てるテストは軒並み agent の状態報告を流すため、張らないと鳴る）。
    AgentSoundOutput.makeOverride = { SoundPlayerFake() }

    // 通知センター。テストの実行体はアプリのバンドルでないので生成点が「使えない」部品にするが、通知センターは人の
    // システム設定に項目が残る実環境なので、ここでも記録だけするフェイクへ向ける。
    SystemNotifierOutput.makeOverride = { SystemNotifierFake() }

    // 取り込んだカスタム音源の置き場。既定は `ORBE_STATE_DIR` 直下＝テスト間で共有される根なので、
    // 書いたファイルが次のテストへ残る。他の永続と同じく caseDir の下へ張り直す。
    CustomSoundStore.directoryURLOverride = dir.appendingPathComponent("sounds", isDirectory: true)

    // 未追跡の破棄の行き先。既定は利用者の実ゴミ箱で、落ちたテストは移したファイルを戻せない。
    GitRepo.trashDirectoryOverride = dir.appendingPathComponent("trash", isDirectory: true)

    // Home のフォルダ。既定は `ORBE_STATE_DIR` 直下＝テスト間で共有される根なので、
    // 一度作ると以降のテストで「あれば触らない」が効いてしまう。caseDir の下へ張り直す。
    HomeFolder.urlOverride = dir.appendingPathComponent(
      "home", isDirectory: true)

    // 子プロセス PATH の probe。張らないと `WindowController` を立てる多数のテストが開発者の
    // 実ログインシェルを起こし、手元の dotfiles で結果が変わる（CI と手元で違う PATH を見る）。
    ShellPATH.shared = ShellPATH(probe: { "/usr/bin:/bin" })
    // 子プロセス PATH に必ず足す既知のディレクトリ。既定は Homebrew などのインストール先を含むので、テストが置いた偽物で
    // ない gh・agent（開発者のログイン済みの gh を含む）が見つかり、偽の gh を置き忘れたテスト 1 本で本物の GitHub へ
    // 書き込みが届く。システムのディレクトリだけにして、テストが PATH に置いたものだけが解決されるようにする（置かなければ
    // 「無い」になる）。
    ShellPATH.knownPathsOverride = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    // gh の設定ディレクトリ。gh が書く設定（hosts.yml など）を開発者のものと分ける。資格情報はこれでは消えない——gh は
    // キーチェーンのトークンを設定ディレクトリに関係なく読むので、本物の gh を解決させない壁は PATH の絞り込みだけ。gh が
    // 書きうるので caseDir の下に置く。
    let ghConfig = dir.appendingPathComponent("gh-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: ghConfig, withIntermediateDirectories: true)
    setenv("GH_CONFIG_DIR", ghConfig.path, 1)

    // 端末のクリップボード。general はシステム全域の実環境で、書けば履歴アプリやユニバーサル
    // クリップボードへ流れ、落ちたテストは開発者の中身を戻せない。テストごとに一意名の pasteboard へ向ける。
    Ghostty.pasteboard = NSPasteboard(
      name: NSPasteboard.Name(
        "dev.orbe.tests.\(stateDir.lastPathComponent).\(dir.lastPathComponent)"))
  }

  /// テスト 1 件の終わり（`tearDown` の後）。
  static func endCase() {
    Ghostty.pasteboard.releaseGlobally()
  }
}

/// SwiftUI のホバーが読むポインタの非表示（AppKit の非公開のクラスメソッド `+[NSCursor _isHidden]`）を、テストの実行体の中で
/// 「非表示ではない」に固定する。メソッドが無いときは差し替えず、`isPinned` を偽のままにする（`TestIsolationTests` の
/// 1 本が落ちる。固定できないときに働かなくなるのは、ホバーに依るテストだけ）。SwiftUI がこのメソッドを読まなくなったことは
/// 検知しない。
enum CursorVisibility {
  private(set) nonisolated(unsafe) static var isPinned = false

  static let selector = NSSelectorFromString("_isHidden")

  static func pinShown() {
    guard let method = class_getClassMethod(NSCursor.self, selector) else { return }
    let shown: @convention(block) (AnyObject) -> Bool = { _ in false }
    method_setImplementation(method, imp_implementationWithBlock(shown))
    isPinned = true
  }
}
