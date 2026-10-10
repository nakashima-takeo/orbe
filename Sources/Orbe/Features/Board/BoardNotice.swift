/// ボードのフッターの右に出す知らせ。部品が置き、ボードは文言と調子だけを描く（中身の種類を知らない）。
struct BoardNotice: Equatable {
  enum Tone: Equatable {
    /// 沈んだ色（済んだこと）。
    case quiet
    /// 赤（断り）。
    case danger
  }

  let message: L10nKey
  let tone: Tone
}
