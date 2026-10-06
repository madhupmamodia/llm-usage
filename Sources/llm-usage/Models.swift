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
