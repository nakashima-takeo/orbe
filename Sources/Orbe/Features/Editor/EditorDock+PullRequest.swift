import SwiftUI

/// PR の画面の、上のバーの右下の置き場の札。
extension EditorDockRoot {
  /// 今出す札を、上から出す順に並べたもの（→ `PrFailureCards`）。置き場の根が描画の中で呼ぶので、観測できる持ち主の値から組む。
  @ViewBuilder var pullRequestCards: some View {
    let cards = PrFailureCards.cards(
      of: reviewPopup.pullRequest, reviewIsOpen: reviewPopup.isOpen, localization)
    ForEach(cards, id: \.kind) { card in
      EditorFailureCard(text: card.text, dismiss: card.dismiss)
    }
  }
}
