import AVFoundation
import UIKit
import XCTest
@testable import LearnChat

/// Runs the real on-device pipeline (PDFKit text layer, Vision OCR/labels, AVFoundation frame
/// sampling) on files generated in the test, so the attachment path is covered end to end.
final class AttachmentPreprocessorTests: XCTestCase {
    private let preprocessor = IOSAttachmentPreprocessor()
    private var tmp: URL!

    override func setUpWithError() throws {
        RequestCaptureURLProtocol.lastRequest = nil
        RequestCaptureURLProtocol.lastRequestBody = nil
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("learnchat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPdfTextLayerIsExtracted() async throws {
        let url = tmp.appendingPathComponent("notes.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { ctx in
            for page in 1...2 {
                ctx.beginPage()
                let text = "Page \(page). Quarterly revenue grew twelve percent and the handbook was updated."
                text.draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }

        let result = try await preprocessor.preprocess(url: url, mimeType: "application/pdf", displayName: "notes.pdf") { _ in }
        guard case .file(let part) = result.part else { return XCTFail("expected a file part") }
        XCTAssertEqual(part.pageCount, 2)
        XCTAssertTrue(part.extractedText?.contains("revenue grew twelve percent") == true, part.extractedText ?? "nil")
        XCTAssertTrue(result.summary.hasPrefix("2 pages"), result.summary)
        XCTAssertTrue(result.part.promptText.contains("[Attached PDF: \"notes.pdf\", 2 pages"))
    }

    func testPhotoIsOcrdAndLabelled() async throws {
        let url = tmp.appendingPathComponent("sign.jpg")
        try makeImage(text: "EXIT").jpegData(compressionQuality: 0.9)!.write(to: url)

        var steps: [String] = []
        let result = try await preprocessor.preprocess(url: url, mimeType: "image/jpeg", displayName: "sign.jpg") { steps.append($0.label) }
        guard case .image(let part) = result.part else { return XCTFail("expected an image part") }
        XCTAssertFalse(part.isVideo)
        XCTAssertTrue(part.extractedText?.contains("EXIT") == true, part.extractedText ?? "nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(string: part.uri)!.path), "downscaled copy should be kept for the bubble")
        XCTAssertFalse(steps.isEmpty)
    }

    func testPhotoWithNoRecognisableContentStillBecomesReady() async throws {
        let url = tmp.appendingPathComponent("blank.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        try image.jpegData(compressionQuality: 0.9)!.write(to: url)

        let result = try await preprocessor.preprocess(url: url, mimeType: "image/jpeg", displayName: "blank.jpg") { _ in }
        guard case .image(let part) = result.part else { return XCTFail("expected an image part") }
        XCTAssertFalse(part.isVideo)
        XCTAssertFalse(result.summary.isEmpty)
    }

    func testVideoFramesAreSampledIntoATimeline() async throws {
        let url = tmp.appendingPathComponent("clip.mp4")
        try await writeVideo(to: url, seconds: 4, text: "HELLO")

        let result = try await preprocessor.preprocess(url: url, mimeType: "video/mp4", displayName: "clip.mp4") { _ in }
        guard case .image(let part) = result.part else { return XCTFail("expected an image (video) part") }
        XCTAssertTrue(part.isVideo)
        XCTAssertNotNil(part.thumbnailUri)
        XCTAssertTrue(part.extractedText?.contains("HELLO") == true, part.extractedText ?? "nil")
        XCTAssertTrue(result.part.promptText.contains("[Attached video \"clip.mp4\""))
    }

    func testVisionRequestIncludesPhotoAndSampledVideoFrame() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestCaptureURLProtocol.self]
        let client = MuseGlimmerChatClient(
            baseUrl: "http://learnchat.test",
            session: URLSession(configuration: config),
            imageEncoder: { "encoded-\($0.name ?? "unnamed")" }
        )
        let turn = ChatTurn(role: .user, parts: [
            .text("What is shown?"),
            .image(ImagePart(uri: "file:///photo.jpg", mimeType: "image/jpeg", name: "photo")),
            .image(ImagePart(
                uri: "file:///clip.mp4",
                mimeType: "video/mp4",
                name: "video-frame",
                thumbnailUri: "file:///frame.jpg"
            )),
        ])

        let reply = try await client.complete(ChatRequest(
            model: "vision",
            turns: [turn],
            includeThinking: false,
            sendImages: true,
            contextTokens: 8_192
        ))

        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(RequestCaptureURLProtocol.lastRequest?.url?.path, "/api/chat")
        let body = try XCTUnwrap(RequestCaptureURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "vision")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["think"] as? Bool, false)
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 8_192)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["images"] as? [String], ["encoded-photo", "encoded-video-frame"])
    }

    // MARK: Fixtures

    private func makeImage(text: String, size: CGSize = CGSize(width: 640, height: 400)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 120), .foregroundColor: UIColor.black]
            let bounds = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2), withAttributes: attrs)
        }
    }

    private func writeVideo(to url: URL, seconds: Int, text: String) async throws {
        let size = CGSize(width: 640, height: 400)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "")
        writer.startSession(atSourceTime: .zero)

        let frame = makeImage(text: text, size: size).cgImage!
        let fps = 10
        for i in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = buffer!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )!
            ctx.draw(frame, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}

private final class RequestCaptureURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
