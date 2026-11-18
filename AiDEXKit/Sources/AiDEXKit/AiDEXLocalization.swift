import Foundation

enum AiDEXLocalization {
    static func string(_ key: String, comment: String = "") -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .module,
            value: key,
            comment: comment
        )
    }
}
