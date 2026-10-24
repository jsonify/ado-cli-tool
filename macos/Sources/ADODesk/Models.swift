import Foundation

/// Arbitrary JSON, used for fields whose shape varies (identity refs, raw ADO fields).
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Human-friendly rendering. Identity refs collapse to their display name.
    var displayText: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return ""
        case .array(let values):
            return values.map(\.displayText).joined(separator: ", ")
        case .object(let object):
            if case .string(let name)? = object["displayName"] { return name }
            if case .string(let name)? = object["uniqueName"] { return name }
            return prettyPrinted
        }
    }

    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Envelope

/// The JSON contract every ado_cli.py command prints to stdout.
struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let command: String?
    let timestamp: String?
    let organization: String?
    let project: String?
    let result: T?
    let error: EnvelopeError?
}

struct EnvelopeError: Decodable {
    let code: String
    let message: String
}

struct CLIFailure: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { "\(message) [\(code)]" }
}

// MARK: - Work items

struct WorkItemSummary: Decodable {
    let id: Int
    let title: String?
    let state: String?
    let parentId: Int?
    let assignedTo: JSONValue?
    let secondaryAssignee: JSONValue?
    let url: String
}

struct WorkItemDetail: Decodable {
    let id: Int
    let title: String?
    let state: String?
    let assignedTo: JSONValue?
    let url: String?
    let fields: [String: JSONValue]

    func field(_ name: String) -> String {
        fields[name]?.displayText ?? ""
    }
}

struct UpdateResult: Decodable {
    let id: Int
    let title: String?
    let state: String?
    let url: String
    let updatedFieldsCount: Int
}

struct DeleteResult: Decodable {
    let id: Int
    let deleted: Bool
}

struct CommentResult: Decodable {
    let id: Int
    let commentId: Int?
}

// MARK: - Iterations

struct Iteration: Codable, Identifiable, Hashable {
    let iterationID: String?
    let name: String?
    let path: String?
    let startDate: String?
    let finishDate: String?
    let timeFrame: String?

    var id: String { iterationID ?? path ?? name ?? "" }

    enum CodingKeys: String, CodingKey {
        case iterationID = "id"
        case name, path, startDate, finishDate, timeFrame
    }
}

struct IterationList: Decodable {
    let count: Int
    let iterations: [Iteration]
}

struct IterationDetail: Decodable {
    let id: String?
    let name: String?
    let path: String?
    let startDate: String?
    let finishDate: String?
    let timeFrame: String?
    let goalText: String?
}

struct GoalResult: Decodable {
    let id: String?
    let name: String?
    let goalText: String?
}

struct IterationPick: Decodable {
    let path: String
    let name: String
    let fiscalYear: String
}

struct ClosedStoriesResult: Decodable {
    struct Summary: Decodable {
        let storyCount: Int
        let totalStoryPoints: Double
        let byAssignee: [String: Int]
        let topTags: [TagCount]
    }

    struct TagCount: Decodable, Hashable {
        let tag: String
        let count: Int
    }

    let summary: Summary
    let stories: [ClosedStory]
}

struct ClosedStory: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let state: String?
    let closedDate: String?
    let assignedTo: String?
    let storyPoints: Double
    let tags: [String]
    let url: String
}

// MARK: - Exports

struct ExportClosedResult: Decodable {
    let count: Int
    let output: String
    let fromDate: String
    let toDate: String?
    let workItemType: String
    let states: [String]
    let assignee: String
}

struct ModificationsResult: Codable {
    let user: String
    let fromDate: String
    let toDate: String?
    let count: Int
    let items: [Modification]
}

struct Modification: Codable, Identifiable, Hashable {
    let workItemID: Int
    let revision: Int?
    let changedDate: String
    let changedBy: String?
    let title: String?
    let state: String?
    let workItemType: String?
    let url: String

    var id: String { "\(workItemID)-\(revision ?? 0)-\(changedDate)" }

    enum CodingKeys: String, CodingKey {
        case workItemID = "id"
        case revision, changedDate, changedBy, title, state, workItemType, url
    }
}
