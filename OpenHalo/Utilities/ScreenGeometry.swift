import CoreGraphics

enum ScreenGeometry {
    /// Convert a normalized bounding box into overlay-local coordinates.
    /// The overlay view uses a top-left origin, matching the AI response.
    static func normalizedToOverlayRect(
        box: AIAnalysisResponse.BoundingBox,
        screenSize: CGSize
    ) -> CGRect {
        let rawX = box.x * screenSize.width
        let rawY = box.y * screenSize.height
        let rawWidth = box.width * screenSize.width
        let rawHeight = box.height * screenSize.height

        let minimumSize = CGSize(width: 24, height: 24)
        let width = min(max(rawWidth, minimumSize.width), screenSize.width)
        let height = min(max(rawHeight, minimumSize.height), screenSize.height)
        let x = clamp(rawX - ((width - rawWidth) / 2), lower: 0, upper: max(screenSize.width - width, 0))
        let y = clamp(rawY - ((height - rawHeight) / 2), lower: 0, upper: max(screenSize.height - height, 0))

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
