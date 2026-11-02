import Foundation

/// 試す対象——保存した定義（自動化）・直す定義（自動化・版・定義）・新しい定義（定義）のどれか 1 つ。書く前の定義は、本番で確かめた
/// 書き込みとして持ち、写しのストアで同じ書き込みを確かめ直して掛けてから流す（本番の書き込みのコードが、足したノードの読み始め・
/// 何をするかが変わったノードの扱い・下げる決まりの当て直しを写しの上で効かせる）。
extension AutomationTrial {
  enum Target {
    /// 保存した定義（自動化の ID）。
    case saved(Int)
    /// 書く前の定義（直す定義は書き換え、新しい定義は作る書き込み）。
    case unsaved(AutomationStore.CheckedWrite)

    /// 置き換えの持ち主: 保存した定義と直す定義はその自動化、新しい定義は持たない。
    var owner: Int? {
      switch self {
      case .saved(let id): id
      case .unsaved(let checked): checked.write.automationId
      }
    }

    /// 始めるときに範囲と与えた行を解く形（保存した定義は本番の自動化のグラフ、書く前の定義は確かめの結果）。定義を読めない自動化の
    /// 保存した定義は断る。
    func shape(in store: AutomationStore) throws(AutomationError) -> Shape {
      switch self {
      case .saved(let id):
        return Shape(nodes: store.automations[try store.index(id)].graph.checked, owner: id)
      case .unsaved(let checked):
        return Shape(nodes: checked.nodes, owner: owner)
      }
    }

    /// 写しの上で流す自動化。保存した定義は写しの自動化をそのまま引き、書く前の定義は写しのストアで同じ書き込みを確かめ直して
    /// 掛ける（写している間に本番の版が進んでいれば、版の食い違いで断る）。
    func automation(on copy: AutomationStore, now: Date) throws(AutomationError) -> Automation {
      switch self {
      case .saved(let id):
        guard let automation = copy.automation(id) else { throw .automationNotFound(id) }
        return automation
      case .unsaved(let checked):
        return try copy.apply(try copy.check(checked.write), now: now).automation
      }
    }
  }
}
