//
//  ClaudeAPIClient.swift
//  ArchiverLib
//

import Foundation

/// Errors that can occur when talking to the Claude API
public enum ClaudeAPIError: Error, Equatable, Sendable {
    case missingApiKey
    case invalidApiKey
    case rateLimited
    case overloaded
    case requestTooLarge
    /// The safety classifiers declined the request (HTTP 200 with `stop_reason: "refusal"`)
    case refused
    case invalidResponse
    case serverError(statusCode: Int)
}

/// Minimal client for the Anthropic Messages API (`POST /v1/messages`)
///
/// There is no official Swift SDK, so this is a thin `URLSession` wrapper.
/// Structured outputs (`output_config.format`) guarantee a JSON response that
/// matches ``DocumentInformationResponse``.
struct ClaudeAPIClient: Sendable {
    struct DocumentInformationResponse: Codable, Sendable {
        let description: String
        let tags: [String]
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    // Server-side refusal fallbacks re-run a declined request on another model
    // in the same call, so benign documents that trip a safety classifier on
    // Claude Opus 5 still get an answer.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        self.urlSession = URLSession(configuration: configuration)
    }

    /// Ask Claude to extract a description and tags from the document text
    /// - Parameters:
    ///   - text: The document text content to analyze
    ///   - systemPrompt: System prompt containing extraction instructions and tag vocabulary
    ///   - model: The Claude model to use
    ///   - apiKey: The user's Anthropic API key
    /// - Returns: The extracted document information
    func extractDocumentInformation(from text: String,
                                    systemPrompt: String,
                                    model: ClaudeModel,
                                    apiKey: String) async throws -> DocumentInformationResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if model == .opus {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(MessagesRequest(model: model, systemPrompt: systemPrompt, text: text))

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw ClaudeAPIError.invalidApiKey
        case 413:
            throw ClaudeAPIError.requestTooLarge
        case 429:
            throw ClaudeAPIError.rateLimited
        case 529:
            throw ClaudeAPIError.overloaded
        default:
            throw ClaudeAPIError.serverError(statusCode: httpResponse.statusCode)
        }

        let messagesResponse = try JSONDecoder().decode(MessagesResponse.self, from: data)

        // A refusal returns HTTP 200 - check stop_reason before reading content
        guard messagesResponse.stopReason != "refusal" else {
            throw ClaudeAPIError.refused
        }
        // A truncated response cannot contain the complete JSON payload
        guard messagesResponse.stopReason != "max_tokens" else {
            throw ClaudeAPIError.invalidResponse
        }
        guard let jsonText = messagesResponse.content.first(where: { $0.type == "text" })?.text,
              let jsonData = jsonText.data(using: .utf8) else {
            throw ClaudeAPIError.invalidResponse
        }

        return try JSONDecoder().decode(DocumentInformationResponse.self, from: jsonData)
    }

    /// Validate an API key with a minimal request
    /// - Returns: `true` if the key was accepted by the API
    func validateApiKey(_ apiKey: String) async -> Bool {
        do {
            _ = try await extractDocumentInformation(from: "test",
                                                     systemPrompt: "Return an empty description and no tags.",
                                                     model: .haiku,
                                                     apiKey: apiKey)
            return true
        } catch ClaudeAPIError.invalidApiKey {
            return false
        } catch ClaudeAPIError.serverError(let statusCode) where (400..<500).contains(statusCode) {
            // A 4xx on this minimal request proves the key or account cannot be used
            return false
        } catch {
            // Other errors (rate limit, overload, network, ...) do not tell us the key is wrong
            return true
        }
    }
}

// MARK: - Wire format

private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: ClaudeModel
    let systemPrompt: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case outputConfig = "output_config"
        case fallbacks
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model.rawValue, forKey: .model)
        try container.encode(1024, forKey: .maxTokens)
        try container.encode(systemPrompt, forKey: .system)
        try container.encode([Message(role: "user", content: text)], forKey: .messages)
        try container.encode(OutputConfig(), forKey: .outputConfig)
        if model == .opus {
            try container.encode("default", forKey: .fallbacks)
        }
    }
}

/// `output_config.format` with a JSON schema guarantees a parseable response
private struct OutputConfig: Encodable {
    struct Format: Encodable {
        let type = "json_schema"
        let schema = Schema()
    }

    struct Schema: Encodable {
        struct Properties: Encodable {
            struct StringProperty: Encodable {
                let type = "string"
                let description: String
            }
            struct TagsProperty: Encodable {
                struct Items: Encodable {
                    let type = "string"
                }
                let type = "array"
                let items = Items()
                let description = "Lowercase single-word tags describing the document, sorted by relevance"
            }

            let description = StringProperty(description: "A short lowercase description of the document without dates")
            let tags = TagsProperty()
        }

        let type = "object"
        let properties = Properties()
        let required = ["description", "tags"]
        let additionalProperties = false
    }

    let format = Format()
}

private struct MessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content: [ContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}
