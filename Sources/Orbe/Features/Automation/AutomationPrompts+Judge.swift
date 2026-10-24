import Foundation

extension AutomationPrompts {
  /// 判定の依頼文。`count` は新しい行の数。判断待ちの候補と付け先にできる workspace は道具で読ませる（回を始める時点に取った
  /// ものを、読みと確かめの両方に使う）。propose も resolve もしない回は report_nothing を呼ばせる——待っている候補を片付ける
  /// だけの回も、何も無い回ではない。
  static func judge(instruction: String, count: Int, now: Date, timeZone: TimeZone) -> String {
    """
    You decide which incoming items should become tasks on the user's task list. \(orbeToolsOnly)

    Now: \(local(now, timeZone)), time zone \(timeZone.identifier).

    The user's instruction:
    \(instruction)

    New items: \(input(count))

    Read the proposals already waiting for the user with \(tool(.readWaitingProposals)), and the workspaces the \
    user works in with \(tool(.readWorkspaces)).

    Give Orbe your decisions:
    - \(tool(.propose)): a task for a new item, {"id": "<item id>", "title": "<one-line task title>", \
    "due": "YYYY-MM-DD", "workspace": <workspace number>, "reason": "<why this item should be a task>"}. \
    Write reason in one or two sentences, in the language of the user's instruction. Omit due when there is no \
    deadline. At most one proposal per item; use only ids of the new items. Write workspace only when the item \
    clearly belongs to one of the listed workspaces (by the user's instruction or by the item itself, such as \
    its repository), using only listed numbers; omit it when unsure, and the task goes to Home.
    - \(tool(.resolve)): the links of waiting proposals that the new items show are already dealt with.
    You can call them more than once; when Orbe refuses a call, fix what it names and call again. Orbe ignores \
    your final text reply.
    If you propose and resolve nothing, call \(tool(.reportNothing)) instead.
    """
  }
}
