import AppKit
import CoreGraphics

struct RefinementRenderings {
    let fullAnnotatedImage: CGImage
    let cropAnnotatedImage: CGImage
    let cropBoxInImage: AIAnalysisResponse.BoundingBox
    let currentBoxInCrop: AIAnalysisResponse.BoundingBox
    let bestBoxInCrop: AIAnalysisResponse.BoundingBox?
    let historyBoxesInCrop: [AIAnalysisResponse.BoundingBox]
    let cropImageSize: CGSize
}

enum AnnotatedScreenshotRenderer {
    static func renderFullImage(
        image: CGImage,
        currentBox: AIAnalysisResponse.BoundingBox,
        historyBoxes: [AIAnalysisResponse.BoundingBox],
        bestPresentationBox: AIAnalysisResponse.BoundingBox?
    ) throws -> CGImage {
        try renderAnnotatedImage(
            image: image,
            currentBox: currentBox,
            historyBoxes: historyBoxes,
            bestPresentationBox: bestPresentationBox
        )
    }

    static func renderRefinementImages(
        image: CGImage,
        currentBox: AIAnalysisResponse.BoundingBox,
        historyBoxes: [AIAnalysisResponse.BoundingBox],
        bestPresentationBox: AIAnalysisResponse.BoundingBox?,
        minimumCropPixelSize: CGSize,
        cropExpansionFactor: Double
    ) throws -> RefinementRenderings {
        let fullAnnotatedImage = try renderAnnotatedImage(
            image: image,
            currentBox: currentBox,
            historyBoxes: historyBoxes,
            bestPresentationBox: bestPresentationBox
        )

        let cropBoxInImage = normalizedCropBox(
            around: currentBox,
            imageSize: CGSize(width: image.width, height: image.height),
            minimumCropPixelSize: minimumCropPixelSize,
            expansionFactor: cropExpansionFactor
        )
        let cropPixelRect = pixelRect(
            for: cropBoxInImage,
            imageWidth: image.width,
            imageHeight: image.height
        )

        guard let cropContext = CGContext(
            data: nil,
            width: Int(cropPixelRect.width),
            height: Int(cropPixelRect.height),
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
                x: CGFloat(-cropPixelRect.minX),
                y: CGFloat(-cropPixelRect.minY),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )

        guard let croppedImage = cropContext.makeImage() else {
            throw AnnotationRenderingError.imageCreationFailed
        }

        let currentBoxInCrop = box(
            currentBox,
            normalizedWithin: cropBoxInImage
        )
        let bestBoxInCrop: AIAnalysisResponse.BoundingBox?
        if let bestPresentationBox, intersects(bestPresentationBox, cropBoxInImage) {
            bestBoxInCrop = box(bestPresentationBox, normalizedWithin: cropBoxInImage)
        } else {
            bestBoxInCrop = nil
        }
        let historyBoxesInCrop: [AIAnalysisResponse.BoundingBox] = historyBoxes.compactMap { historyBox in
            guard intersects(historyBox, cropBoxInImage) else { return nil }
            return box(historyBox, normalizedWithin: cropBoxInImage)
        }
        let cropAnnotatedImage = try renderAnnotatedImage(
            image: croppedImage,
            currentBox: currentBoxInCrop,
            historyBoxes: historyBoxesInCrop,
            bestPresentationBox: bestBoxInCrop
        )

        return RefinementRenderings(
            fullAnnotatedImage: fullAnnotatedImage,
            cropAnnotatedImage: cropAnnotatedImage,
            cropBoxInImage: cropBoxInImage,
            currentBoxInCrop: currentBoxInCrop,
            bestBoxInCrop: bestBoxInCrop,
            historyBoxesInCrop: historyBoxesInCrop,
            cropImageSize: CGSize(width: croppedImage.width, height: croppedImage.height)
        )
    }

    private static func renderAnnotatedImage(
        image: CGImage,
        currentBox: AIAnalysisResponse.BoundingBox,
        historyBoxes: [AIAnalysisResponse.BoundingBox],
        bestPresentationBox: AIAnalysisResponse.BoundingBox?
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

        let normalizedHistory = historyBoxes.map { $0.clampedToUnitSpace() }
        let rect = pixelRect(
            for: currentBox.clampedToUnitSpace(),
            imageWidth: width,
            imageHeight: height
        )

        let focusPath = CGMutablePath()
        focusPath.addRect(CGRect(x: 0, y: 0, width: width, height: height))
        focusPath.addRect(rect.insetBy(dx: -1, dy: -1))
        context.addPath(focusPath)
        context.setFillColor(NSColor.black.withAlphaComponent(0.26).cgColor)
        context.drawPath(using: .eoFill)

        drawHistory(
            on: context,
            boxes: normalizedHistory,
            imageWidth: width,
            imageHeight: height
        )

        if let bestPresentationBox {
            drawBestPresentationBox(
                on: context,
                box: bestPresentationBox,
                currentBox: currentBox,
                imageWidth: width,
                imageHeight: height
            )
        }

        let outerStrokeColor = NSColor.white
        let innerStrokeColor = NSColor.systemPink

        context.setStrokeColor(outerStrokeColor.cgColor)
        context.setLineWidth(10)
        context.stroke(rect)

        context.setStrokeColor(innerStrokeColor.cgColor)
        context.setLineWidth(6)
        context.stroke(rect)

        drawCornerHandles(on: context, rect: rect, color: innerStrokeColor)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(3)
        context.move(to: CGPoint(x: center.x - 14, y: center.y))
        context.addLine(to: CGPoint(x: center.x + 14, y: center.y))
        context.move(to: CGPoint(x: center.x, y: center.y - 14))
        context.addLine(to: CGPoint(x: center.x, y: center.y + 14))
        context.strokePath()

        guard let annotatedImage = context.makeImage() else {
            throw AnnotationRenderingError.imageCreationFailed
        }

        return annotatedImage
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

    private static func drawHistory(
        on context: CGContext,
        boxes: [AIAnalysisResponse.BoundingBox],
        imageWidth: Int,
        imageHeight: Int
    ) {
        guard !boxes.isEmpty else { return }

        let rects = boxes.map {
            pixelRect(
                for: $0,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        }

        if rects.count > 1 {
            context.saveGState()
            context.setLineDash(phase: 0, lengths: [10, 8])
            context.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(4)

            for index in 0..<(rects.count - 1) {
                let start = CGPoint(x: rects[index].midX, y: rects[index].midY)
                let end = CGPoint(x: rects[index + 1].midX, y: rects[index + 1].midY)
                context.move(to: start)
                context.addLine(to: end)
            }
            context.strokePath()
            context.restoreGState()
        }

        for (index, rect) in rects.dropLast().enumerated() {
            let progress = Double(index + 1) / Double(max(rects.count - 1, 1))
            let historyColor = NSColor.systemYellow.withAlphaComponent(0.28 + (0.26 * progress))

            context.saveGState()
            context.setLineDash(phase: 0, lengths: [14, 8])
            context.setStrokeColor(historyColor.cgColor)
            context.setLineWidth(4)
            context.stroke(rect)

            context.setFillColor(historyColor.withAlphaComponent(0.18).cgColor)
            let centerDot = CGRect(
                x: rect.midX - 5,
                y: rect.midY - 5,
                width: 10,
                height: 10
            )
            context.fillEllipse(in: centerDot)
            context.restoreGState()
        }
    }

    private static func drawBestPresentationBox(
        on context: CGContext,
        box: AIAnalysisResponse.BoundingBox,
        currentBox: AIAnalysisResponse.BoundingBox,
        imageWidth: Int,
        imageHeight: Int
    ) {
        let normalizedBest = box.clampedToUnitSpace()
        guard !normalizedBest.isClose(to: currentBox.clampedToUnitSpace(), threshold: 0.0015) else {
            return
        }

        let rect = pixelRect(
            for: normalizedBest,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        context.saveGState()
        context.setLineDash(phase: 0, lengths: [18, 10])
        context.setStrokeColor(NSColor.systemGreen.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(6)
        context.stroke(rect)

        context.setFillColor(NSColor.systemGreen.withAlphaComponent(0.18).cgColor)
        let centerDot = CGRect(
            x: rect.midX - 6,
            y: rect.midY - 6,
            width: 12,
            height: 12
        )
        context.fillEllipse(in: centerDot)
        context.restoreGState()
    }

    private static func drawCornerHandles(
        on context: CGContext,
        rect: CGRect,
        color: NSColor
    ) {
        let handleLength = max(16.0, min(36.0, min(rect.width, rect.height) * 0.4))

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(8)

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

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create drawing context"
        case .imageCreationFailed:
            return "Failed to create annotated screenshot"
        }
    }
}
