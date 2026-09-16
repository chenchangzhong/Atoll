import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// a4f2img: Scoped QuickLook preview service for images and videos only, with hard guardrails
/// (size caps, timeout, single-worker queue). Other file types never enter Quick Look,
/// so archives/other content cannot trigger preview-side memory spikes.
final class ImagePreviewService {
    static let shared = ImagePreviewService()

    private let queue = DispatchQueue(label: "com.Ebullioscopic.Atoll.imagePreview", qos: .utility)
    private static let maxBytes: Int64 = 100_000_000
    // a4f2img: videos decode a single frame only, so the entry cost does not scale with file
    // size; a wider cap (1GB) stays cheap under the remaining guardrails.
    private static let maxVideoBytes: Int64 = 1_000_000_000
    private let timeoutSeconds: UInt64 = 2_000_000_000

    static func isPreviewableImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) else {
            return false
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if type.conforms(to: .image) {
            return Int64(size) <= maxBytes
        }
        return Int64(size) <= maxVideoBytes
    }

    /// Returns a Quick Look thumbnail for previewable images, or nil (caller falls back
    /// to the system icon). Never blocks the main thread; single worker queue.
    func thumbnail(for url: URL) async -> NSImage? {
        guard Self.isPreviewableImage(url) else { return nil }
        return await withCheckedContinuation { [timeoutSeconds] continuation in
            let state = GuardedCompletion(continuation: continuation)
            // Timeout guard: if Quick Look stalls, fall back to the system icon.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: timeoutSeconds)
                state.finish(with: nil)
            }
            queue.async {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: 300, height: 300),
                    scale: 2,
                    representationTypes: .all
                )
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    state.finish(with: representation?.nsImage)
                }
            }
        }
    }

    private final class GuardedCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<NSImage?, Never>?

        init(continuation: CheckedContinuation<NSImage?, Never>) {
            self.continuation = continuation
        }

        func finish(with image: NSImage?) {
            lock.lock()
            guard !finished, let continuation = continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: image)
        }
    }
}
