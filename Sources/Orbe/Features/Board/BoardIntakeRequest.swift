/// 自動追加の部品の依頼の欄の中身: 打った文と、直す相手の札（札が無ければ新しい依頼）。
struct BoardIntakeRequest: Equatable {
  /// 直す相手。名前は札を付けた時点のもの（札の表示だけに使い、送るときは今のストアから引き直す）。
  struct Fix: Equatable {
    let id: Int
    let name: String
  }

  var text = ""
  var fix: Fix?
}
