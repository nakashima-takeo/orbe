import OrbeSound
import XCTest

@testable import Orbe

/// タスク由来の知らせ（ファイル分割の拡張）。待ちの条件が解けると、agent の通知と同じ②ピルと通知音に
/// 「workspace 名・#番号 起きたこと」が出る。そのタスクを ⌘⇧X で見ているときは出ない。ピルのクリックは
/// ⌘⇧X でそのタスクを選んで開く。
///
/// 壊れると何が起きるか: タスクのピルが次の chrome の再投影で即座に閉じる。読む設定が見ている workspace の
/// ものになる。見ているタスクでも鳴る。クリックしてもタスクが絞り込みに隠れたまま見つからない。言語選択や
/// オンボーディングの最中に ⌘⇧X へ差し替わる。
extension WindowControllerReportAgentTests {
  /// 待ちの条件を付けたタスクを足し、`output` を出して満たす（nil なら期限で解く）。
  private func resolveTask(
    _ wc: WindowController, title: String = "設定の検索を速くする", workspace: UUID? = nil,
    links: [TaskLink] = [], output: String? = "レビューが付いた\n@sato"
  ) throws -> (id: Int, resolution: WaitResolution) {
    var draft = TaskDraft(title: title)
    draft.workspace = workspace
    draft.links = links
    draft.waitingReason = "レビュー待ち"
    draft.waitingCondition = WaitConditionRequest(
      description: "PR #214 にレビューが付いたら", command: "exit 1", everyMinutes: 10,
      deadline: Date().addingTimeInterval(3600))
    let task = try wc.taskStore.add(draft)
    let condition = try XCTUnwrap(task.waiting?.condition?.id)
    let now = Date()
    let resolution =
      if let output {
        wc.taskStore.recordCheck(
          task.id, condition: condition,
          BackgroundRunResult(
            commandLine: "exit 1", startedAt: now, endedAt: now, ending: .exited(0),
            output: .command(stdout: .init(data: Data(output.utf8)), stderr: .init())))
      } else {
        wc.taskStore.expire(task.id, condition: condition)
      }
    return (task.id, try XCTUnwrap(resolution, "前提: 解けている"))
  }

  /// 初回起動の言語選択（真のモーダル）を下ろした窓。⌘⇧X を開くテストの足場。
  private func launchWithoutFirstRun() throws -> WindowController {
    let (wc, _) = try makeControllerAndTab()
    wc.dismissPalette()
    return wc
  }

  private func pr214() throws -> TaskLink {
    TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/orbe", number: 214)), kind: .pr)
  }

  /// 背面で解けると、タスクの workspace の名前と「#番号 起きたこと」のピルが、その workspace の滞留で立ち、
  /// 完了の音がその workspace の設定で鳴る。直後の chrome の再投影（一覧の差し替え）でも取り下がらない。
  func testTaskNoticeStandsAndSurvivesReprojection() throws {
    let (wc, _) = try makeControllerAndTwoActivatedWorkspaces()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let origin = wc.regularWorkspaces[0]
    var override = SettingsLayer()
    override[SettingKeys.notificationSound] = .preset(.steel)
    override[SettingKeys.notificationSoundVolume] = 30
    override[SettingKeys.menuBarNotificationDuration] = 40
    origin.settingsOverride = override
    XCTAssertFalse(wc.current === origin, "前提: タスクの workspace はアクティブでない方")
    let (id, resolution) = try resolveTask(
      wc, workspace: origin.persistentId, links: [try pr214()])

    wc.notifyWaitResolved(task: id, resolution)

    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(
      transient.taskNotice,
      TaskNotice(taskId: id, workspaceName: origin.name, text: "#214 レビューが付いた"))
    XCTAssertEqual(transient.expiresAt.timeIntervalSince(transient.arrivedAt), 40, accuracy: 0.001)
    XCTAssertEqual(sound.played, [.synth(.steel, event: .done, volume: 30)])

    wc.refreshChrome()
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.transient?.retracted, false, "再投影でタスクのピルを取り下げない")
    XCTAssertEqual(wc.attentionStore.count, 0, "件数は agent だけを数える")
  }

  /// 結び付きが無ければ番号の代わりにタイトル、期限なら「期限が来た」。workspace が無ければ名前の欄は無く、
  /// 全体の設定で鳴る。
  func testTaskNoticeWithoutLinkOrWorkspace() throws {
    let (wc, _) = try makeControllerAndTab()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSound, .preset(.wood)))
    let (id, resolution) = try resolveTask(wc, title: "見積もりの数字を経理に確認する", output: nil)

    wc.notifyWaitResolved(task: id, resolution)

    XCTAssertEqual(
      wc.attentionStore.transient?.taskNotice,
      TaskNotice(
        taskId: id, workspaceName: nil,
        text: "見積もりの数字を経理に確認する " + wc.localization.string(.taskWaitExpired)))
    XCTAssertEqual(sound.played, [.synth(.wood, event: .done, volume: 90)])
  }

  /// 前面の ⌘⇧X でそのタスクを選んでいれば、ピルも音も出ない。別のタスクが解けたときは出る。
  func testTaskNoticeSuppressedWhileViewingThatTask() throws {
    let wc = try launchWithoutFirstRun()
    makeKey(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let viewed = try resolveTask(wc)
    let other = try resolveTask(wc, title: "別のタスク")
    wc.showTaskPalette(selecting: viewed.id)

    wc.notifyWaitResolved(task: viewed.id, viewed.resolution)
    XCTAssertNil(wc.attentionStore.transient, "見ているタスクではピルを立てない")
    XCTAssertTrue(sound.played.isEmpty, "見ているタスクでは鳴らさない")

    wc.notifyWaitResolved(task: other.id, other.resolution)
    XCTAssertEqual(wc.attentionStore.transient?.taskNotice?.taskId, other.id)
    XCTAssertEqual(sound.played.count, 1)
  }

  /// ピルのクリックは ⌘⇧X を開いてそのタスクを選ぶ。絞り込みで隠れていても見えるようにする。
  func testTaskPillClickSelectsTheTask() throws {
    let wc = try launchWithoutFirstRun()
    let (id, _) = try resolveTask(wc)
    wc.showTaskPalette()
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.query = "一致しない"

    wc.showTaskPalette(selecting: id)

    XCTAssertEqual(wc.presentedOverlay, .taskPalette)
    XCTAssertTrue(wc.model.taskPalette === palette, "開いている画面のまま選び直す")
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(id))
  }

  /// 差し替えてはならない画面（言語選択・オンボーディング・更新内容）の間は ⌘⇧X を開かない。
  func testTaskPillClickKeepsModalOverlay() throws {
    let wc = try launchWithoutFirstRun()
    let (id, _) = try resolveTask(wc)
    for overlay in [AppShellModel.Overlay.languageSelect, .onboarding, .updateChanges] {
      wc.model.overlay = overlay
      wc.showTaskPalette(selecting: id)
      XCTAssertEqual(wc.presentedOverlay, overlay)
      XCTAssertNil(wc.model.taskPalette)
    }
  }
}
