import Foundation

@testable import Orbe

extension DesignSceneFixtures {
  /// 番人もノードの回も止まった走らせ役。`workspaces` は走らせ役が読む今の workspace。
  static func automationRunner(
    _ samples: [AutomationSample] = [],
    workspaces: AutomationWorkspaces = AutomationWorkspaces(all: [], home: nil)
  ) -> AutomationRunner {
    automationRunner(store: automationStore(samples), workspaces: workspaces)
  }

  /// `store` の上の、番人もノードの回も止まった走らせ役。
  static func automationRunner(
    store: AutomationStore,
    workspaces: AutomationWorkspaces = AutomationWorkspaces(all: [], home: nil)
  ) -> AutomationRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { automationNow }
    scheduler.calendar = { taskCalendar }
    scheduler.arm = { _, _ in {} }
    let runner = AutomationRunner(
      store: store, scheduler: scheduler,
      run: { _, _ in BackgroundRunHandle {} },
      workspaces: { workspaces }, recorded: { _ in },
      defined: { _ in }, deleted: { _ in })
    runner.now = { automationNow }
    runner.calendar = { taskCalendar }
    runner.start()
    return runner
  }
}
