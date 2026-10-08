import Foundation

struct DailyMetrics: Codable {
    let spend: Double
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    let api_requests: Int
}

struct ModelMetrics: Codable {
    let metrics: DailyMetrics
}

struct Breakdown: Codable {
    let models: [String: ModelMetrics]?
}

struct DailyActivity: Codable, Identifiable {
    var id: String { date }
    let date: String
    let metrics: DailyMetrics
    let breakdown: Breakdown?
}

struct ActivityMetadata: Codable {
    let total_spend: Double
    let total_api_requests: Int?
}

struct ActivityResponse: Codable {
    let results: [DailyActivity]
    let metadata: ActivityMetadata?
}

// MARK: - Budget (from /user/info)

struct UserInfoPayload: Codable {
    let max_budget: Double?
    let spend: Double
    let budget_duration: String?
    let budget_reset_at: String?
}

struct UserInfoResponse: Codable {
    let user_id: String?
    let user_info: UserInfoPayload
}

// MARK: - Models (from /models)

struct AvailableModel: Codable, Identifiable, Equatable {
    let id: String
    let max_input_tokens: Int?
    let max_output_tokens: Int?
}

struct ModelDetail: Codable, Equatable {
    let model_name: String
    let input_per_million: Double?
    let output_per_million: Double?
    let max_input_tokens: Int?
    let max_output_tokens: Int?
    let cache_read_per_million: Double?
    let cache_creation_per_million: Double?
}

// /v2/model/info response
struct ModelInfoResponse: Codable {
    let data: [ModelInfoRow]
}

struct ModelInfoRow: Codable {
    let model_name: String
    let model_info: ModelInfoFields
}

struct ModelInfoFields: Codable {
    let input_cost_per_token: Double?
    let output_cost_per_token: Double?
    let max_input_tokens: Int?
    let max_output_tokens: Int?
    let cache_creation_input_token_cost: Double?
    let cache_read_input_token_cost: Double?
}

struct ModelsAPIResponse: Codable {
    let data: [AvailableModel]
}

struct ModelsCache: Codable {
    let fetched_at: Date
    let models: [AvailableModel]
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Spend log (from /spend/logs/v2)

struct SpendLogMetadata: Codable {
    let status: String?
    let error_information: SpendLogError?
    let usage_object: SpendLogUsage?
}

struct SpendLogError: Codable {
    let error_type: String?
    let error_message: String?
    let error_code: String?
}

struct SpendLogUsage: Codable {
    let total_tokens: Int?
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let cache_read_input_tokens: Int?
}

struct SpendLogEntry: Codable {
    let request_id: String?
    let model: String?
    let spend: Double?
    let total_tokens: Int?
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let startTime: String?
    let endTime: String?
    let metadata: SpendLogMetadata?
}

struct SpendLogResponse: Codable {
    let data: [SpendLogEntry]?
    let total: Int?
}

// MARK: - Telemetry (computed client-side from spend logs)

struct ModelLatency: Identifiable {
    var id: String { model }
    let model: String
    let count: Int
    let p50: Double
    let p95: Double
}

struct Telemetry {
    var sampleSize: Int = 0
    var totalInRange: Int = 0                 // total logs in date range, may exceed sampleSize
    var wasCapped: Bool = false               // true if totalInRange > sampleSize
    var latencyByModel: [ModelLatency] = []   // top 5 by request count
    var totalRequests: Int = 0
    var errorCount: Int = 0
    var errorRate: Double = 0                 // 0.0 - 1.0
    var topFailingModel: (name: String, count: Int)?
    var cacheHitRate: Double = 0              // 0.0 - 1.0
    var cacheTokensSaved: Int = 0
}
