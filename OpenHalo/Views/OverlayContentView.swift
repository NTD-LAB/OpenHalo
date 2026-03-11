import SwiftUI

struct OverlayContentView: View {
    let highlights: [HighlightRegion]
    let screenSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(highlights) { region in
                HighlightRectangleView(region: region)
                    .frame(
                        width: max(region.screenRect.width, 1),
                        height: max(region.screenRect.height, 1),
                        alignment: .topLeading
                    )
                    .offset(
                        x: region.screenRect.minX,
                        y: region.screenRect.minY
                    )
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
