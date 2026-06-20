import Foundation

public struct RingoAdminClient: Sendable {
    public let baseURL: URL
    public let token: String

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        token: String = ProcessInfo.processInfo.environment["AFM_BRIDGE_API_KEY"] ?? RingoRuntime.localToken
    ) {
        self.baseURL = baseURL
        self.token = token
    }

    public func request(path: String, method: String = "GET") async throws -> String {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RingoError.bridgeFailed("invalid management URL path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown response"
            throw RingoError.bridgeFailed("management request failed: \(detail)")
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func escapedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
