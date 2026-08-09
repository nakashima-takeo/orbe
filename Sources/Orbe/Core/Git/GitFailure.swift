import Foundation

/// git 操作の失敗理由。**文言は持たない**（UI 言語は chrome の責務で、Git 層は理由だけを返す）。
/// モデル層がこれを受けて文言へ写す。
enum GitFailure: Equatable {
  /// 無出力が続いて打ち切った。git は何も言い残していないので、chrome が文言を用意する。
  case timedOut
  /// git の stderr から取り出した実質的な理由。そのまま見せる。
  case reason(String)
}
