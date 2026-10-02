import AppKit
import ImageIO

nonisolated struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// Decodes and downsamples images off the main thread, keyed by path+size.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "wa.images", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 600 }

    func cached(_ path: String, px: Int) -> NSImage? {
        cache.object(forKey: "\(path)#\(px)" as NSString)
    }

    /// `px` is the longest edge in pixels; images are never decoded larger than that.
    func load(_ path: String, px: Int, _ done: @escaping (NSImage?) -> Void) {
        let key = "\(path)#\(px)"
        if let img = cache.object(forKey: key as NSString) { done(img); return }
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        queue.async {
            let cg = ImageCache.decode(URL(fileURLWithPath: path), px: px)
            let box = UncheckedBox(value: cg)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let img = box.value.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2)) }
                    if let img { self.cache.setObject(img, forKey: key as NSString) }
                    let cbs = self.waiting.removeValue(forKey: key) ?? []
                    for cb in cbs { cb(img) }
                }
            }
        }
    }

    nonisolated static func decode(_ url: URL, px: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Inline JPEG thumbnails are tiny; decode synchronously.
    static func thumb(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        return NSImage(data: data)
    }
}
