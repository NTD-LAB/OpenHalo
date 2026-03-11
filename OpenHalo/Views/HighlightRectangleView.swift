import SwiftUI

struct HighlightRectangleView: View {
    let region: HighlightRegion
    @State private var isPulsing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Semi-transparent fill
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor.opacity(0.15))
                .frame(width: region.screenRect.width, height: region.screenRect.height)

            // Animated border
            RoundedRectangle(cornerRadius: 6)
                .stroke(highlightColor, lineWidth: 3)
                .frame(width: region.screenRect.width, height: region.screenRect.height)
                .scaleEffect(isPulsing ? 1.02 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isPulsing
                )

            // Label badge
            if !region.label.isEmpty {
                Text(labelText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(highlightColor.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: 4, y: -24)
            }
        }
        .onAppear { isPulsing = true }
    }

    private var labelText: String {
        if let step = region.stepNumber {
            return "\(step). \(region.label)"
        }
        return region.label
    }

    private var highlightColor: Color {
        switch region.color {
        case .primary: return .blue
        case .secondary: return .green
        case .warning: return .orange
        }
    }
}
