/// 閉じた文書から手放す大きな部品——本文の写し・保存時の本文・役割の並び・構文木を持つ構文の裏の仕事（比較・行差分・
/// 検索・出現の裏の仕事は依頼の後に本文を覚えず、仕事の間は走っている裏の仕事が自分を持つので、ここに入れない）。
struct ReleasedParts: Sendable {
  let text: TextRope
  let synced: TextRope
  let roles: RoleRuns
  let syntax: SyntaxWorker?
}
