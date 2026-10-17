import AVFoundation
import Foundation

struct SampledFrame: Sendable {
    var timeMs: Int64
    var image: CGImage
}

struct VideoSample: Sendable {
    var durationMs: Int64
    var frames: [SampledFrame]
}

/// Pulls a handful of evenly spaced frames out of a video with AVFoundation's image generator
/// (hardware decoder, no copy of the clip is made). Each frame is then treated like a photo by the caller.
struct VideoFrameSampler: Sendable {
    var maxSide: Int = 960

    func sample(_ url: URL, maxFrames: Int, onFrame: @escaping @Sendable (_ index: Int, _ total: Int) -> Void) async throws -> VideoSample {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = duration.isNumeric ? Int64((duration.seconds * 1000).rounded()) : 0
        // Short clips get fewer frames: roughly one every 5 s, at least 1, at most maxFrames.
        let count = durationMs <= 0 ? 1 : min(max(Int(durationMs / 5_000) + 1, 1), maxFrames)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        // Like Android's OPTION_CLOSEST_SYNC: accept the nearest keyframe instead of decoding exactly.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2.5, preferredTimescale: 600)

        var frames: [SampledFrame] = []
        for i in 0..<count {
            try Task.checkCancellation()
            onFrame(i + 1, count)
            // Spread across the clip but stay clear of the very last frame, which often fails to decode.
            let t: Int64 = count == 1 ? durationMs / 2 : (durationMs * Int64(i)) / Int64(count) + (durationMs / Int64(count)) / 2
            let time = CMTime(seconds: Double(t) / 1000, preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(SampledFrame(timeMs: t, image: image.scaledTo(maxSide)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        if frames.isEmpty { throw PreprocessError("Could not decode any frames from this video") }
        return VideoSample(durationMs: durationMs, frames: frames)
    }
}
