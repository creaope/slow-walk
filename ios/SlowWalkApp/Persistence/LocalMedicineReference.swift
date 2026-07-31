import Foundation
import SwiftData

/// Empty local medicine index schema.
///
/// Fields exist for a later trusted data import; this issue intentionally
/// ships no medicine rows and no medical statements.
@Model
final class LocalMedicineReference {
    @Attribute(.unique) var stableID: String
    var genericName: String
    var brandNames: [String]
    var packagingKeywords: [String]
    var manufacturer: String?
    var dataSource: String
    var dataVersion: String
    var updatedAt: Date

    init(
        stableID: String,
        genericName: String,
        brandNames: [String],
        packagingKeywords: [String],
        manufacturer: String?,
        dataSource: String,
        dataVersion: String,
        updatedAt: Date
    ) {
        self.stableID = stableID
        self.genericName = genericName
        self.brandNames = brandNames
        self.packagingKeywords = packagingKeywords
        self.manufacturer = manufacturer
        self.dataSource = dataSource
        self.dataVersion = dataVersion
        self.updatedAt = updatedAt
    }
}
