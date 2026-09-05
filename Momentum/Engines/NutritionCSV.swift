import Foundation

enum NutritionCSV {
    struct Row {
        let id: UUID
        let eatenAt: Date
        let name: String
        let source: String
        let nutrition: NutritionValues
        var kind: String = "meal"
    }

    static func encode(_ rows: [Row]) -> String {
        let header = ["entry_id", "recorded_at_utc", "entry", "source", "entry_type"]
            + Nutrient.allCases.map { "\($0.rawValue)_\($0.unit)" }
        let lines = rows.map { row in
            [row.id.uuidString, row.eatenAt.ISO8601Format(), cell(row.name), cell(row.source), cell(row.kind)]
                + Nutrient.allCases.map { field in
                    guard let value = row.nutrition[field], value.isFinite else { return "" }
                    return value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                        .grouping(.never).precision(.fractionLength(0...field.precision)))
                }
        }
        return ([header] + lines).map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoting protects delimiters; a leading apostrophe also blocks spreadsheet formulas.
    static func cell(_ text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true || text.hasPrefix("\t") || text.hasPrefix("\r")
            ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
