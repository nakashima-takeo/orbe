/// 閉じた文書から手放す大きな部品——本文の写し・役割の並び・構文木を持つ構文の裏の仕事・アウトライン（行差分・検索・出現の
/// 裏の仕事は依頼の後に本文を覚えず、仕事の間は走っている裏の仕事が自分を持つので、ここに入れない）。
struct ReleasedParts: Sendable {
  let text: TextRope
  let roles: RoleRuns
  let syntax: SyntaxWorker?
  let outline: OutlineState.Parts
}
