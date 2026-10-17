import Foundation

/// Wire format of the Muse Glimmer service's POST /api/chat endpoint.
struct MuseGlimmerMessage: Codable {
    var role: String
    var content: String = ""
    var thinking: String? = nil
    /// Base64 photos, only honoured by vision-capable models.
    var images: [String]? = nil
}

struct MuseGlimmerChatRequest: Encodable {
    var model: String
    var messages: [MuseGlimmerMessage]
    var stream: Bool
    var think: Bool? = nil
    var options: MuseGlimmerOptions? = nil
}

struct MuseGlimmerOptions: Encodable {
    var numCtx: Int? = nil

    enum CodingKeys: String, CodingKey { case numCtx = "num_ctx" }
}

struct MuseGlimmerChatChunk: Decodable {
    var model: String? = nil
    var message: MuseGlimmerMessage? = nil
    var done: Bool = false
    var doneReason: String? = nil
    var totalDurationNs: Int64? = nil
    var evalCount: Int? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey {
        case model, message, done, error
        case doneReason = "done_reason"
        case totalDurationNs = "total_duration"
        case evalCount = "eval_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        message = try c.decodeIfPresent(MuseGlimmerMessage.self, forKey: .message)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        doneReason = try c.decodeIfPresent(String.self, forKey: .doneReason)
        totalDurationNs = try c.decodeIfPresent(Int64.self, forKey: .totalDurationNs)
        evalCount = try c.decodeIfPresent(Int.self, forKey: .evalCount)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct MuseGlimmerModelsResponse: Decodable {
    var models: [MuseGlimmerModel] = []
}

struct MuseGlimmerModel: Decodable {
    var name: String
}
