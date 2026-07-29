import Foundation

public protocol MedicineKnowledgeSource: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var priority: Int { get }
    var isAuthoritative: Bool { get }
    var supportedDataVersion: String { get }

    func search(
        query: MedicineKnowledgeSourceQuery
    ) async throws -> MedicineKnowledgeSourceResponse

    func fetchMedicine(
        identifier: String
    ) async throws -> MedicineKnowledgeSourceResponse
}

public protocol MedicineKnowledgeSearching: Sendable {
    func search(
        query: MedicineKnowledgeQuery
    ) async throws -> MedicineKnowledgeSearchResult
}

@available(macOS 14.0, iOS 17.0, *)
public protocol HTTPTransporting: Sendable {
    func send(
        _ request: HTTPTransportRequest
    ) async throws -> HTTPTransportResponse
}

public struct MedicineKnowledgeCacheEntry:
    Sendable,
    Equatable
{
    public let normalizedQuery: String
    public let sourceResponses: [String: MedicineKnowledgeSourceResponse]
    public let result: MedicineKnowledgeSearchResult
    public let storedAt: Date
    public let expiresAt: Date
    public let offlineUseUntil: Date

    public init(
        normalizedQuery: String,
        sourceResponses: [String: MedicineKnowledgeSourceResponse],
        result: MedicineKnowledgeSearchResult,
        storedAt: Date,
        expiresAt: Date,
        offlineUseUntil: Date
    ) {
        self.normalizedQuery = normalizedQuery
        self.sourceResponses = sourceResponses
        self.result = result
        self.storedAt = storedAt
        self.expiresAt = expiresAt
        self.offlineUseUntil = offlineUseUntil
    }
}

public struct MedicineKnowledgeCacheLookup:
    Sendable,
    Equatable
{
    public let status: MedicineKnowledgeCacheStatus
    public let entry: MedicineKnowledgeCacheEntry?
    public let canUseOffline: Bool

    public init(
        status: MedicineKnowledgeCacheStatus,
        entry: MedicineKnowledgeCacheEntry? = nil,
        canUseOffline: Bool = false
    ) {
        self.status = status
        self.entry = entry
        self.canUseOffline = canUseOffline
    }
}

public protocol MedicineKnowledgeCaching: Sendable {
    func lookup(
        normalizedQuery: String,
        now: Date
    ) async throws -> MedicineKnowledgeCacheLookup

    func store(
        result: MedicineKnowledgeSearchResult,
        sourceResponses: [String: MedicineKnowledgeSourceResponse],
        now: Date
    ) async throws

    func remove(normalizedQuery: String) async throws
    func removeAll() async throws
}
