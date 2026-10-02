import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

enum PhotoRenderingError: Error {
    case unreadableImage
    case couldNotRender
}

enum PhotoRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: true])

    static func preview(data: Data, look: FilmLook, frame: PrintFrame) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { return nil }
        let input = CIImage(cgImage: thumbnail)
        guard let filtered = apply(look, to: input),
              let output = context.createCGImage(filtered, from: filtered.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return framed(UIImage(cgImage: output), style: frame, date: Date())
    }

    static func finalJPEG(data: Data, look: FilmLook, frame: PrintFrame, date: Date = Date()) throws -> Data {
        guard let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw PhotoRenderingError.unreadableImage
        }
        guard let filtered = apply(look, to: input),
              let output = context.createCGImage(filtered, from: filtered.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PhotoRenderingError.couldNotRender
        }
        let result = framed(UIImage(cgImage: output), style: frame, date: date)
        guard let jpeg = result.jpegData(compressionQuality: 0.97) else { throw PhotoRenderingError.couldNotRender }
        return jpeg
    }

    private static func apply(_ look: FilmLook, to image: CIImage) -> CIImage? {
        guard look != .original else { return image }
        switch look {
        case .original:
            return image
        case .clean:
            return color(image, saturation: 1.08, contrast: 1.04, brightness: 0.005)
        case .p400:
            guard let adjusted = color(image, saturation: 0.91, contrast: 1.13, brightness: -0.01) else { return nil }
            return vignette(adjusted, intensity: 0.18, radius: 1.5)
        case .harbor:
            guard let adjusted = color(image, saturation: 0.88, contrast: 1.06, brightness: 0.015) else { return nil }
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = adjusted
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 7900, y: 8)
            return temperature.outputImage
        case .dusk:
            guard let adjusted = color(image, saturation: 1.12, contrast: 1.10, brightness: -0.015) else { return nil }
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = adjusted
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5250, y: 12)
            return vignette(temperature.outputImage ?? adjusted, intensity: 0.22, radius: 1.35)
        case .relic:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.32
            guard let tinted = sepia.outputImage,
                  let adjusted = color(tinted, saturation: 0.72, contrast: 1.12, brightness: 0.01) else { return nil }
            return vignette(adjusted, intensity: 0.28, radius: 1.25)
        case .mono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            return mono.outputImage
        }
    }

    private static func color(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage? {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = saturation
        filter.contrast = contrast
        filter.brightness = brightness
        return filter.outputImage
    }

    private static func vignette(_ image: CIImage, intensity: Float, radius: Float) -> CIImage? {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = intensity
        filter.radius = Float(max(image.extent.width, image.extent.height)) * radius
        return filter.outputImage
    }

    private static func framed(_ image: UIImage, style: PrintFrame, date: Date) -> UIImage {
        guard style != .none else { return image }
        let imageSize = image.size
        let margin = max(28, imageSize.width * 0.055)
        let footer = style == .speed || style == .date ? max(46, imageSize.width * 0.055) : margin
        let canvasSize = CGSize(width: imageSize.width + margin * 2, height: imageSize.height + margin + footer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let paperColor: UIColor = style == .paper ? UIColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1) : .white

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { renderer in
            let bounds = CGRect(origin: .zero, size: canvasSize)
            renderer.cgContext.setFillColor(paperColor.cgColor)
            renderer.cgContext.fill(bounds)
            image.draw(in: CGRect(x: margin, y: margin, width: imageSize.width, height: imageSize.height))

            guard style == .speed || style == .date else { return }
            let label: String
            if style == .date {
                label = date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased()
            } else {
                label = "SHOT WITH FRAMEWISE"
            }
            let font = UIFont.systemFont(ofSize: max(10, imageSize.width * 0.018), weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black.withAlphaComponent(0.58),
                .kern: max(0.4, imageSize.width * 0.0008)
            ]
            let textSize = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: (canvasSize.width - textSize.width) / 2,
                                                  y: imageSize.height + margin + (footer - textSize.height) / 2),
                                     withAttributes: attributes)
        }
    }
}
