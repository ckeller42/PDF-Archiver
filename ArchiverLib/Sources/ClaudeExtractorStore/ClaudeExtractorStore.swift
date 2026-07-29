//
//  ClaudeExtractorStore.swift
//  ArchiverLib
//

import ArchiverModels
import Foundation
import OSLog
import Shared

/// Extract document information (description and tags) using the Claude API
///
/// Cloud-based alternative to the on-device Apple Intelligence extraction in
/// `ContentExtractorStore` - usable on devices where Apple Intelligence is not
/// available. Requires a user-provided Anthropic API key (stored in the Keychain).
public actor ClaudeExtractorStore: Log {
    public struct Info: Sendable {
        public let specification: String
        public let tags: [String]
    }

    // Claude has a large context window, but bounding the text keeps cost and latency in check
    private static let maxTextLength = 40_000
    private static let maxVocabularyTags = 100

    private let apiClient = ClaudeAPIClient()

    public init() {}

    /// `true` if an API key is stored in the Keychain
    public static func isConfigured() -> Bool {
        ClaudeAPIKeyStore.get() != nil
    }

    /// Store or delete (`nil` / empty string) the API key
    public static func setApiKey(_ apiKey: String?) {
        ClaudeAPIKeyStore.set(apiKey)
    }

    /// Validate the stored API key against the API
    public func validateStoredApiKey() async -> Bool {
        guard let apiKey = ClaudeAPIKeyStore.get() else { return false }
        return await apiClient.validateApiKey(apiKey)
    }

    /// Extract document information using the Claude API
    /// - Parameters:
    ///   - text: The document text content to analyze
    ///   - customPrompt: Optional custom prompt to guide the extraction
    ///   - model: The Claude model to use
    ///   - documents: Existing documents for context (tag vocabulary)
    /// - Returns: Extracted specification and tags, or nil if no API key is configured
    public func extract(from text: String,
                        customPrompt: String?,
                        model: ClaudeModel,
                        with documents: [Document]) async throws -> Info? {
        guard let apiKey = ClaudeAPIKeyStore.get() else { return nil }

        let systemPrompt = Self.createSystemPrompt(customPrompt: customPrompt, documents: documents)
        let truncatedText = String(text.prefix(Self.maxTextLength))

        let response = try await apiClient.extractDocumentInformation(from: truncatedText,
                                                                      systemPrompt: systemPrompt,
                                                                      model: model,
                                                                      apiKey: apiKey)

        return Info(specification: response.description.trimmingCharacters(in: .whitespacesAndNewlines),
                    tags: response.tags.prefix(10).map { $0.slugified(withSeparator: "") })
    }

    private static func createSystemPrompt(customPrompt: String?, documents: [Document]) -> String {
        var prompt = """
        You are a document archiving assistant. Analyze the document content and extract:
        - description: a short, meaningful description of the document (lowercase, a few words, no dates, in the document's language)
        - tags: 3 to 10 lowercase single-word tags that categorize the document (e.g. sender, document type, topic)

        Prefer tags from the user's existing tag vocabulary when they fit the document.
        """

        let vocabulary = tagVocabulary(from: documents)
        if !vocabulary.isEmpty {
            prompt += "\n\nExisting tags of the user:\n\(vocabulary.joined(separator: ", "))"
        }

        if let customPrompt,
           !customPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from the user:\n\(customPrompt)"
        }

        return prompt
    }

    /// Most frequently used tags across the archive, limited to keep the prompt small
    private static func tagVocabulary(from documents: [Document]) -> [String] {
        var counts: [String: Int] = [:]
        for document in documents {
            for tag in document.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(maxVocabularyTags)
            .map(\.key)
    }
}
