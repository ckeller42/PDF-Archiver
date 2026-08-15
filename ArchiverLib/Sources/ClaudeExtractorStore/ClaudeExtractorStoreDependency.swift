//
//  ClaudeExtractorStoreDependency.swift
//  ArchiverLib
//

import ArchiverModels
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

@DependencyClient
public struct ClaudeExtractorStoreDependency: Sendable {
    /// Input for document information extraction
    public struct DocInfoInput: Sendable {
        /// Existing documents for context (tag vocabulary)
        public let currentDocuments: [Document]
        /// The document text content to analyze
        public let text: String
        /// Optional custom prompt to guide the extraction
        public let customPrompt: String?
        /// The Claude model to use
        public let model: ClaudeModel

        public init(currentDocuments: [Document], text: String, customPrompt: String?, model: ClaudeModel) {
            self.currentDocuments = currentDocuments
            self.text = text
            self.customPrompt = customPrompt
            self.model = model
        }
    }

    /// Output from document information extraction
    public struct DocInfo: Sendable {
        /// Extracted document specification/description
        public let specification: String
        /// Extracted document tags
        public let tags: Set<String>
    }

    private static let claudeExtractorStore = ClaudeExtractorStore()

    /// Check if an API key is stored in the Keychain
    public var isConfigured: @Sendable () async -> Bool = { false }

    /// Store or delete (nil / empty string) the API key in the Keychain
    public var setApiKey: @Sendable (String?) async -> Void = { _ in }

    /// Validate the stored API key against the API
    public var validateStoredApiKey: @Sendable () async -> Bool = { false }

    /// Extract document information using the Claude API
    /// - Parameter input: Input containing text, documents context, custom prompt and model
    /// - Returns: Extracted specification and tags, or nil if unavailable
    public var getDocumentInformation: @Sendable (DocInfoInput) async -> DocInfo?
}

extension ClaudeExtractorStoreDependency: TestDependencyKey {
    public static let previewValue = Self(
        isConfigured: { true },
        setApiKey: { _ in },
        validateStoredApiKey: { true },
        getDocumentInformation: { _ in nil }
    )

    public static let testValue = Self()
}

extension ClaudeExtractorStoreDependency: DependencyKey {
    public static let liveValue = ClaudeExtractorStoreDependency(
        isConfigured: {
            ClaudeExtractorStore.isConfigured()
        },
        setApiKey: { apiKey in
            ClaudeExtractorStore.setApiKey(apiKey)
        },
        validateStoredApiKey: {
            await claudeExtractorStore.validateStoredApiKey()
        },
        getDocumentInformation: { input in
            do {
                guard let result = try await claudeExtractorStore.extract(from: input.text,
                                                                          customPrompt: input.customPrompt,
                                                                          model: input.model,
                                                                          with: input.currentDocuments) else { return nil }

                return DocInfo(specification: result.specification,
                               tags: Set(result.tags))
            } catch let error as ClaudeAPIError {
                switch error {
                case .missingApiKey, .invalidApiKey:
                    Logger.claudeExtractor.warning("Claude extraction failed - API key missing or invalid")

                case .rateLimited:
                    Logger.claudeExtractor.warning("Claude extraction rate limited")

                case .overloaded:
                    Logger.claudeExtractor.warning("Claude API temporarily overloaded")

                case .requestTooLarge:
                    Logger.claudeExtractor.warning("Document too large for Claude extraction")

                case .refused:
                    Logger.claudeExtractor.warning("Claude declined to extract content")

                case .invalidResponse:
                    Logger.claudeExtractor.warning("Received an invalid response from the Claude API")

                case .serverError(let statusCode):
                    Logger.claudeExtractor.warning("Claude API returned server error \(statusCode)")
                }
                return nil
            } catch {
                Logger.claudeExtractor.error("An error occurred while extracting document content via Claude", metadata: ["error": "\(error)"])
                return nil
            }
        }
    )
}

public extension DependencyValues {
    var claudeExtractorStore: ClaudeExtractorStoreDependency {
        get { self[ClaudeExtractorStoreDependency.self] }
        set { self[ClaudeExtractorStoreDependency.self] = newValue }
    }
}
