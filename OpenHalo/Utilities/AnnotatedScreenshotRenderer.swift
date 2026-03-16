import AppKit
import CoreGraphics

struct RenderedEpisodeCandidate: Equatable {
    enum Role {
        case active
        case best
        case history
    }

    let candidateID: String
    let box: AIAnalysisResponse.BoundingBox
    let qualityScore: Int
    let role: Role
}

struct RefinementRenderings {
    let fullAnnotatedImage: CGImage
    let cropAnnotatedImage: CGImage
    let activeContentImage: CGImage
    let activeContentBoxInImage: AIAnalysisResponse.BoundingBox
    let cropBoxInImage: AIAnalysisResponse.BoundingBox
    let candidatesInCrop: [RenderedEpisodeCandidate]
    let cropImageSize: CGSize
}

enum AnnotatedScreenshotRenderer {
    private enum RenderingStyle {
        case fullContext
        case detailCrop
    }

    static func renderRefinementImages(
        image: CGImage,
        displayedCandidates: [RenderedEpisodeCandidate],
        activeCandidateID: String,
        minimumCropPixelSize: CGSize,
        cropExpansionFactor: Double,
        minimumActiveContentRenderSize: CGSize,
        actionCanvasGhostOffsetRange: ClosedRange<Int>
    ) throws -> RefinementRenderings {
        let activeCandidate = try requiredActiveCandidate(
            from: displayedCandidates,
            activeCandidateID: activeCandidateID
        )

        let fullAnnotatedImage = try renderAnnotatedImage(
            image: image,
            displayedCandidates: displayedCandidates,
            activeCandidateID: activeCandidateID,
            style: .fullContext,
            actionCanvasGhostOffsetRange: actionCanvasGhostOffsetRange
        )

        let cropBoxInImage = normalizedCropBox(
            around: activeCandidate.box,
            imageSize: CGSize(width: image.width, height: image.height),
            minimumCropPixelSize: minimumCropPixelSize,
            expansionFactor: cropExpansionFactor
        )
        let cropPixelRect = pixelRect(
            for: cropBoxInImage,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let croppedImage = try cropImage(image: image, pixelRect: cropPixelRect)

        let candidatesInCrop = displayedCandidates.compactMap { candidate -> RenderedEpisodeCandidate? in
            guard intersects(candidate.box, cropBoxInImage) else { return nil }
            return RenderedEpisodeCandidate(
                candidateID: candidate.candidateID,
                box: box(candidate.box, normalizedWithin: cropBoxInImage),
                qualityScore: candidate.qualityScore,
                role: candidate.role
            )
        }

        let cropAnnotatedImage = try renderAnnotatedImage(
            image: croppedImage,
            displayedCandidates: candidatesInCrop,
            activeCandidateID: activeCandidateID,
            style: .detailCrop,
            actionCanvasGhostOffsetRange: actionCanvasGhostOffsetRange
        )

        let activeContentBoxInImage = activeCandidate.box.clampedToUnitSpace(minimumExtent: 0.0)
        let activeContentPixelRect = pixelRect(
            for: activeContentBoxInImage,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let activeContentImage = try cropImage(
            image: image,
            pixelRect: activeContentPixelRect,
            minimumOutputSize: minimumActiveContentRenderSize
        )

        return RefinementRenderings(
            fullAnnotatedImage: fullAnnotatedImage,
            cropAnnotatedImage: cropAnnotatedImage,
            activeContentImage: activeContentImage,
            activeContentBoxInImage: activeContentBoxInImage,
            cropBoxInImage: cropBoxInImage,
            candidatesInCrop: candidatesInCrop,
            cropImageSize: CGSize(width: croppedImage.width, height: croppedImage.height)
        )
    }

    private static func renderAnnotatedImage(
        image: CGImage,
        displayedCandidates: [RenderedEpisodeCandidate],
        activeCandidateID: String,
        style: RenderingStyle,
        actionCanvasGhostOffsetRange: ClosedRange<Int>
    ) throws -> CGImage {
        let width = image.width
        let height = image.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationRenderingError.contextCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let activeCandidate = try requiredActiveCandidate(
            from: displayedCandidates,
            activeCandidateID: activeCandidateID
        )
        let activeRect = pixelRect(
            for: activeCandidate.box.clampedToUnitSpace(),
            imageWidth: width,
            imageHeight: height
        )

        if style == .fullContext {
            let focusPath = CGMutablePath()
            focusPath.addRect(CGRect(x: 0, y: 0, width: width, height: height))
            focusPath.addRect(activeRect.insetBy(dx: -1, dy: -1))
            context.addPath(focusPath)
            context.setFillColor(NSColor.black.withAlphaComponent(0.14).cgColor)
            context.drawPath(using: .eoFill)
        }

        drawActionCanvas(
            on: context,
            activeCandidate: activeCandidate,
            imageWidth: width,
            imageHeight: height,
            style: style,
            ghostOffsetRange: actionCanvasGhostOffsetRange
        )

        for candidate in displayedCandidates where candidate.role == .history {
            drawHistoryCandidate(
                on: context,
                candidate: candidate,
                imageWidth: width,
                imageHeight: height,
                style: style
            )
        }

        for candidate in displayedCandidates where candidate.role == .best {
            drawBestCandidate(
                on: context,
                candidate: candidate,
                activeCandidate: activeCandidate,
                imageWidth: width,
                imageHeight: height,
                style: style
            )
        }

        drawActiveCandidate(
            on: context,
            candidate: activeCandidate,
            imageWidth: width,
            imageHeight: height,
            style: style
        )

        guard let annotatedImage = context.makeImage() else {
            throw AnnotationRenderingError.imageCreationFailed
        }

        return annotatedImage
    }

    private static func drawActionCanvas(
        on context: CGContext,
        activeCandidate: RenderedEpisodeCandidate,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle,
        ghostOffsetRange: ClosedRange<Int>
    ) {
        let activeRect = pixelRect(
            for: activeCandidate.box.clampedToUnitSpace(),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let origin = CGPoint(x: activeRect.midX, y: activeRect.midY)
        let unitWidth = max(activeRect.width, 8)
        let unitHeight = max(activeRect.height, 8)
        let maxHalfStepOffset = Double(ghostOffsetRange.upperBound) + 0.5

        drawActionAxes(
            on: context,
            origin: origin,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            style: style
        )

        if style == .detailCrop {
            drawHalfStepGrid(
                on: context,
                origin: origin,
                unitWidth: unitWidth,
                unitHeight: unitHeight,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                maxOffset: maxHalfStepOffset
            )
        }

        drawGhostBoxes(
            on: context,
            origin: origin,
            activeRect: activeRect,
            unitWidth: unitWidth,
            unitHeight: unitHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            style: style,
            ghostOffsetRange: ghostOffsetRange
        )

        drawAxisTicksAndLabels(
            on: context,
            origin: origin,
            unitWidth: unitWidth,
            unitHeight: unitHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            style: style,
            ghostOffsetRange: ghostOffsetRange
        )
    }

    private static func drawActionAxes(
        on context: CGContext,
        origin: CGPoint,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle
    ) {
        context.saveGState()
        context.setStrokeColor(
            NSColor.systemTeal.withAlphaComponent(style == .detailCrop ? 0.30 : 0.22).cgColor
        )
        context.setLineWidth(style == .detailCrop ? 2 : 1.5)

        context.move(to: CGPoint(x: 0, y: origin.y))
        context.addLine(to: CGPoint(x: CGFloat(imageWidth), y: origin.y))
        context.move(to: CGPoint(x: origin.x, y: 0))
        context.addLine(to: CGPoint(x: origin.x, y: CGFloat(imageHeight)))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawHalfStepGrid(
        on context: CGContext,
        origin: CGPoint,
        unitWidth: CGFloat,
        unitHeight: CGFloat,
        imageWidth: Int,
        imageHeight: Int,
        maxOffset: Double
    ) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 6])

        var offset = -maxOffset
        while offset <= maxOffset + 0.000_1 {
            let isInteger = abs(offset.rounded() - offset) < 0.000_1
            let isOrigin = abs(offset) < 0.000_1
            if !isInteger && !isOrigin {
                let x = origin.x + (CGFloat(offset) * unitWidth)
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: CGFloat(imageHeight)))

                let y = origin.y - (CGFloat(offset) * unitHeight)
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: CGFloat(imageWidth), y: y))
            }
            offset += 0.5
        }

        context.strokePath()
        context.restoreGState()
    }

    private static func drawGhostBoxes(
        on context: CGContext,
        origin: CGPoint,
        activeRect: CGRect,
        unitWidth: CGFloat,
        unitHeight: CGFloat,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle,
        ghostOffsetRange: ClosedRange<Int>
    ) {
        context.saveGState()
        context.setStrokeColor(
            NSColor.systemTeal.withAlphaComponent(style == .detailCrop ? 0.28 : 0.18).cgColor
        )
        context.setLineWidth(style == .detailCrop ? 2 : 1.5)
        context.setLineDash(phase: 0, lengths: [8, 8])

        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)

        for xOffset in ghostOffsetRange {
            for yOffset in ghostOffsetRange {
                if xOffset == 0 && yOffset == 0 {
                    continue
                }

                let candidateRect = CGRect(
                    x: origin.x + (CGFloat(xOffset) * unitWidth) - (activeRect.width / 2),
                    y: origin.y - (CGFloat(yOffset) * unitHeight) - (activeRect.height / 2),
                    width: activeRect.width,
                    height: activeRect.height
                ).integral

                guard candidateRect.intersects(imageBounds) else { continue }
                context.stroke(candidateRect)
            }
        }

        context.restoreGState()
    }

    private static func drawAxisTicksAndLabels(
        on context: CGContext,
        origin: CGPoint,
        unitWidth: CGFloat,
        unitHeight: CGFloat,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle,
        ghostOffsetRange: ClosedRange<Int>
    ) {
        context.saveGState()
        context.setStrokeColor(
            NSColor.systemTeal.withAlphaComponent(style == .detailCrop ? 0.42 : 0.30).cgColor
        )
        context.setLineWidth(1.5)

        for offset in ghostOffsetRange {
            let x = origin.x + (CGFloat(offset) * unitWidth)
            context.move(to: CGPoint(x: x, y: origin.y - 5))
            context.addLine(to: CGPoint(x: x, y: origin.y + 5))

            let y = origin.y - (CGFloat(offset) * unitHeight)
            context.move(to: CGPoint(x: origin.x - 5, y: y))
            context.addLine(to: CGPoint(x: origin.x + 5, y: y))
        }

        context.strokePath()
        context.restoreGState()

        for offset in ghostOffsetRange where offset != 0 {
            let x = origin.x + (CGFloat(offset) * unitWidth)
            drawAxisLabel(
                on: context,
                text: "\(offset)",
                point: CGPoint(x: x + 4, y: min(max(origin.y + 8, 8), CGFloat(imageHeight) - 22)),
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )

            let y = origin.y - (CGFloat(offset) * unitHeight)
            drawAxisLabel(
                on: context,
                text: "\(offset)",
                point: CGPoint(x: min(max(origin.x + 8, 8), CGFloat(imageWidth) - 22), y: y + 4),
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        }

        drawAxisLabel(
            on: context,
            text: "0,0",
            point: CGPoint(
                x: min(max(origin.x + 8, 8), CGFloat(imageWidth) - 34),
                y: min(max(origin.y + 8, 8), CGFloat(imageHeight) - 22)
            ),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    private static func drawAxisLabel(
        on context: CGContext,
        text: String,
        point: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemTeal.withAlphaComponent(0.92)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: min(max(point.x, 4), CGFloat(imageWidth) - textSize.width - 4),
            y: min(max(point.y, 4), CGFloat(imageHeight) - textSize.height - 4),
            width: textSize.width,
            height: textSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        (text as NSString).draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func requiredActiveCandidate(
        from displayedCandidates: [RenderedEpisodeCandidate],
        activeCandidateID: String
    ) throws -> RenderedEpisodeCandidate {
        if let active = displayedCandidates.first(where: {
            $0.candidateID == activeCandidateID && $0.role == .active
        }) {
            return active
        }
        if let active = displayedCandidates.first(where: { $0.candidateID == activeCandidateID }) {
            return active
        }
        throw AnnotationRenderingError.activeCandidateMissing
    }

    private static func normalizedCropBox(
        around currentBox: AIAnalysisResponse.BoundingBox,
        imageSize: CGSize,
        minimumCropPixelSize: CGSize,
        expansionFactor: Double
    ) -> AIAnalysisResponse.BoundingBox {
        let clampedBox = currentBox.clampedToUnitSpace(minimumExtent: 0.0)
        let imageWidth = max(imageSize.width, 1.0)
        let imageHeight = max(imageSize.height, 1.0)
        let minimumWidth = min(max(minimumCropPixelSize.width / imageWidth, 0.0), 1.0)
        let minimumHeight = min(max(minimumCropPixelSize.height / imageHeight, 0.0), 1.0)
        let cropWidth = min(max(clampedBox.width * expansionFactor, minimumWidth), 1.0)
        let cropHeight = min(max(clampedBox.height * expansionFactor, minimumHeight), 1.0)
        let centerX = clampedBox.x + (clampedBox.width / 2)
        let centerY = clampedBox.y + (clampedBox.height / 2)

        return AIAnalysisResponse.BoundingBox(
            x: centerX - (cropWidth / 2),
            y: centerY - (cropHeight / 2),
            width: cropWidth,
            height: cropHeight
        ).clampedToUnitSpace(minimumExtent: 0.0)
    }

    private static func cropImage(
        image: CGImage,
        pixelRect: CGRect,
        minimumOutputSize: CGSize? = nil
    ) throws -> CGImage {
        let outputWidth = max(
            Int(pixelRect.width),
            Int((minimumOutputSize?.width ?? 0).rounded(.up))
        )
        let outputHeight = max(
            Int(pixelRect.height),
            Int((minimumOutputSize?.height ?? 0).rounded(.up))
        )

        guard let cropContext = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationRenderingError.contextCreationFailed
        }

        cropContext.interpolationQuality = .high
        cropContext.draw(
            image,
            in: CGRect(
                x: CGFloat(-pixelRect.minX) * (CGFloat(outputWidth) / max(pixelRect.width, 1)),
                y: CGFloat(-pixelRect.minY) * (CGFloat(outputHeight) / max(pixelRect.height, 1)),
                width: CGFloat(image.width) * (CGFloat(outputWidth) / max(pixelRect.width, 1)),
                height: CGFloat(image.height) * (CGFloat(outputHeight) / max(pixelRect.height, 1))
            )
        )

        guard let croppedImage = cropContext.makeImage() else {
            throw AnnotationRenderingError.imageCreationFailed
        }

        return croppedImage
    }

    private static func pixelRect(
        for box: AIAnalysisResponse.BoundingBox,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let width = Double(imageWidth)
        let height = Double(imageHeight)

        return CGRect(
            x: box.x * width,
            y: (1.0 - box.y - box.height) * height,
            width: box.width * width,
            height: box.height * height
        ).integral
    }

    private static func box(
        _ globalBox: AIAnalysisResponse.BoundingBox,
        normalizedWithin container: AIAnalysisResponse.BoundingBox
    ) -> AIAnalysisResponse.BoundingBox {
        let mapped = AIAnalysisResponse.BoundingBox(
            x: (globalBox.x - container.x) / max(container.width, 0.000_001),
            y: (globalBox.y - container.y) / max(container.height, 0.000_001),
            width: globalBox.width / max(container.width, 0.000_001),
            height: globalBox.height / max(container.height, 0.000_001)
        )

        return mapped.clampedToUnitSpace(minimumExtent: 0.0)
    }

    private static func intersects(
        _ lhs: AIAnalysisResponse.BoundingBox,
        _ rhs: AIAnalysisResponse.BoundingBox
    ) -> Bool {
        let lhsMaxX = lhs.x + lhs.width
        let lhsMaxY = lhs.y + lhs.height
        let rhsMaxX = rhs.x + rhs.width
        let rhsMaxY = rhs.y + rhs.height

        return lhs.x < rhsMaxX &&
            lhsMaxX > rhs.x &&
            lhs.y < rhsMaxY &&
            lhsMaxY > rhs.y
    }

    private static func drawHistoryCandidate(
        on context: CGContext,
        candidate: RenderedEpisodeCandidate,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle
    ) {
        let rect = pixelRect(
            for: candidate.box.clampedToUnitSpace(),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        context.saveGState()
        context.setLineDash(phase: 0, lengths: [14, 8])
        context.setStrokeColor(
            NSColor.systemYellow.withAlphaComponent(style == .detailCrop ? 0.48 : 0.72).cgColor
        )
        context.setLineWidth(style == .detailCrop ? 3 : 4)
        context.stroke(rect)
        context.restoreGState()

        if style == .fullContext {
            drawBadge(
                on: context,
                text: badgeText(for: candidate),
                rect: rect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                fillColor: NSColor.systemYellow.withAlphaComponent(0.92),
                textColor: NSColor.black
            )
        }
    }

    private static func drawBestCandidate(
        on context: CGContext,
        candidate: RenderedEpisodeCandidate,
        activeCandidate: RenderedEpisodeCandidate,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle
    ) {
        let normalizedBest = candidate.box.clampedToUnitSpace()
        guard !normalizedBest.isClose(to: activeCandidate.box.clampedToUnitSpace(), threshold: 0.0015) else {
            return
        }

        let rect = pixelRect(
            for: normalizedBest,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        context.saveGState()
        context.setLineDash(phase: 0, lengths: [16, 10])
        context.setStrokeColor(
            NSColor.systemGreen.withAlphaComponent(style == .detailCrop ? 0.58 : 0.96).cgColor
        )
        context.setLineWidth(style == .detailCrop ? 4 : 6)
        context.stroke(rect)
        context.restoreGState()

        if style == .fullContext {
            drawBadge(
                on: context,
                text: badgeText(for: candidate),
                rect: rect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                fillColor: NSColor.systemGreen.withAlphaComponent(0.94),
                textColor: NSColor.white
            )
        }
    }

    private static func drawActiveCandidate(
        on context: CGContext,
        candidate: RenderedEpisodeCandidate,
        imageWidth: Int,
        imageHeight: Int,
        style: RenderingStyle
    ) {
        let rect = pixelRect(
            for: candidate.box.clampedToUnitSpace(),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let outerStrokeColor = NSColor.white.withAlphaComponent(style == .detailCrop ? 0.42 : 0.72)
        let innerStrokeColor = NSColor.systemRed.withAlphaComponent(style == .detailCrop ? 0.56 : 0.82)

        context.setStrokeColor(outerStrokeColor.cgColor)
        context.setLineWidth(style == .detailCrop ? 5 : 8)
        context.stroke(rect)

        context.setStrokeColor(innerStrokeColor.cgColor)
        context.setLineWidth(style == .detailCrop ? 3 : 4)
        context.stroke(rect)

        if style == .fullContext {
            drawCornerHandles(on: context, rect: rect, color: innerStrokeColor)
            drawBadge(
                on: context,
                text: badgeText(for: candidate),
                rect: rect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                fillColor: NSColor.systemRed.withAlphaComponent(0.94),
                textColor: NSColor.white
            )
        }
    }

    private static func badgeText(for candidate: RenderedEpisodeCandidate) -> String {
        let numericID = candidate.candidateID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "c", with: "")
        return "#\(numericID) \(candidate.qualityScore)"
    }

    private static func drawBadge(
        on context: CGContext,
        text: String,
        rect: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        fillColor: NSColor,
        textColor: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: textColor
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let paddingX: CGFloat = 12
        let paddingY: CGFloat = 6
        let badgeWidth = textSize.width + (paddingX * 2)
        let badgeHeight = textSize.height + (paddingY * 2)
        let maxX = CGFloat(imageWidth) - badgeWidth - 6
        let preferredAboveY = rect.maxY + 6
        let preferredBelowY = rect.minY - badgeHeight - 6
        let badgeX = min(max(rect.minX, 6), max(maxX, 6))
        let badgeY: CGFloat
        if preferredAboveY + badgeHeight <= CGFloat(imageHeight) - 6 {
            badgeY = preferredAboveY
        } else if preferredBelowY >= 6 {
            badgeY = preferredBelowY
        } else {
            badgeY = min(max(rect.minY + 6, 6), CGFloat(imageHeight) - badgeHeight - 6)
        }

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight).integral

        context.saveGState()
        context.setFillColor(fillColor.cgColor)
        context.addPath(
            CGPath(
                roundedRect: badgeRect,
                cornerWidth: 8,
                cornerHeight: 8,
                transform: nil
            )
        )
        context.fillPath()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        (text as NSString).draw(
            in: CGRect(
                x: badgeRect.minX + paddingX,
                y: badgeRect.minY + paddingY,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCornerHandles(
        on context: CGContext,
        rect: CGRect,
        color: NSColor
    ) {
        let handleLength = max(16.0, min(36.0, min(rect.width, rect.height) * 0.4))

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(6)

        drawCorner(
            on: context,
            origin: CGPoint(x: rect.minX, y: rect.minY),
            horizontalDelta: handleLength,
            verticalDelta: handleLength
        )
        drawCorner(
            on: context,
            origin: CGPoint(x: rect.maxX, y: rect.minY),
            horizontalDelta: -handleLength,
            verticalDelta: handleLength
        )
        drawCorner(
            on: context,
            origin: CGPoint(x: rect.minX, y: rect.maxY),
            horizontalDelta: handleLength,
            verticalDelta: -handleLength
        )
        drawCorner(
            on: context,
            origin: CGPoint(x: rect.maxX, y: rect.maxY),
            horizontalDelta: -handleLength,
            verticalDelta: -handleLength
        )
        context.strokePath()
    }

    private static func drawCorner(
        on context: CGContext,
        origin: CGPoint,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat
    ) {
        context.move(to: origin)
        context.addLine(to: CGPoint(x: origin.x + horizontalDelta, y: origin.y))
        context.move(to: origin)
        context.addLine(to: CGPoint(x: origin.x, y: origin.y + verticalDelta))
    }
}

enum AnnotationRenderingError: Error, LocalizedError {
    case contextCreationFailed
    case imageCreationFailed
    case activeCandidateMissing

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create drawing context"
        case .imageCreationFailed:
            return "Failed to create annotated screenshot"
        case .activeCandidateMissing:
            return "Missing active candidate for annotated screenshot"
        }
    }
}
