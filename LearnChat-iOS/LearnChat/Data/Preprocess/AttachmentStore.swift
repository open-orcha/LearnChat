import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Name / size / MIME of a picked file.
struct PickedFileInfo: Sendable {
    var displayName: String
    var sizeBytes: Int64?
    var mimeType: String?
}

/// Keeps attachments under `Application Support/attachments/`. URLs from the Files / Photos
/// pickers are temporary or security-scoped, so anything we want to show again (thumbnails, the
/// PDF) is copied here first.
struct AttachmentStore: Sendable {
    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func describe(_ url: URL, fallbackName: String?, fallbackMime: String?) -> PickedFileInfo {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedNameKey])
        let name = fallbackName ?? values?.localizedName ?? url.lastPathComponent
        let size = values?.fileSize.map { Int64($0) }
        let mime = fallbackMime
            ?? values?.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
        return PickedFileInfo(displayName: name.isEmpty ? "file" : name, sizeBytes: size, mimeType: mime)
    }

    /// Copies the file behind `url` into app storage and returns the new file.
    func copyIn(_ url: URL, extension ext: String) throws -> URL {
        let target = newFile(ext)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw PreprocessError("Could not open the selected file")
        }
        return target
    }

    /// Decodes the image at `url` scaled so its longest side is at most `maxSide`, applying EXIF
    /// rotation. Large photos are downsampled during decode to keep memory in check.
    func decodeScaled(_ url: URL, maxSide: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PreprocessError("Could not decode image") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreprocessError("Could not decode image")
        }
        return image
    }

    /// Writes `image` as a JPEG into app storage.
    func saveJpeg(_ image: CGImage, quality: CGFloat = 0.85) throws -> URL {
        let target = newFile("jpg")
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: quality) else { throw PreprocessError("Could not encode image") }
        try data.write(to: target)
        return target
    }

    private func newFile(_ ext: String) -> URL { dir.appendingPathComponent("\(UUID().uuidString).\(ext)") }
}

extension CGImage {
    /// Scales so the longest side is at most `maxSide`; returns the same image if already small enough.
    func scaledTo(_ maxSide: Int) -> CGImage {
        let longest = max(width, height)
        if longest <= maxSide { return self }
        let scale = CGFloat(maxSide) / CGFloat(longest)
        let size = CGSize(width: (CGFloat(width) * scale).rounded(), height: (CGFloat(height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: self).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.cgImage ?? self
    }
}
