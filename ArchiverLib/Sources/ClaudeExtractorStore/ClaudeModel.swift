//
//  ClaudeModel.swift
//  ArchiverLib
//

import Foundation

/// Claude models that can be selected for document information extraction
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Highest quality model - recommended default
    case opus = "claude-opus-5"
    /// Fast and cost-effective model for simple documents
    case haiku = "claude-haiku-4-5"

    public var id: String { rawValue }

    public static let `default`: ClaudeModel = .opus
}
