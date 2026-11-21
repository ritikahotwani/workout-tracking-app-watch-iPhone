import Foundation

/// RFC 4180 CSV: quoted fields, `""` escapes, commas and line breaks inside quotes, CRLF or LF, leading BOM.
public enum CSV {
    public struct Row: Sendable, Equatable {
        /// 1-based physical line the row starts on (the header is line 1).
        public let line: Int
        public let fields: [String]
    }

    /// Parses every non-blank row. Lenient: a stray quote inside an unquoted field is kept as text, and an
    /// unterminated quoted field runs to the end of the input.
    public static func parse(_ text: String) -> [Row] {
        var rows: [Row] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var line = 1, rowLine = 1
        // Scalars, not Characters: "\r\n" is a single Character in Swift.
        var it = text.unicodeScalars.makeIterator()
        var pending = it.next()
        if pending == "\u{FEFF}" { pending = it.next() }

        func endRow() {
            fields.append(String(field))
            field = .init()
            if fields != [""] { rows.append(Row(line: rowLine, fields: fields)) }
            fields = []
        }

        while let c = pending {
            pending = it.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" { field.append("\""); pending = it.next() } else { inQuotes = false }
                } else {
                    if c == "\n" || (c == "\r" && pending != "\n") { line += 1 }
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: inQuotes = true
            case ",": fields.append(String(field)); field = .init()
            case "\r" where pending == "\n": continue  // the "\n" ends the row
            case "\n", "\r":
                endRow()
                line += 1
                rowLine = line
            default: field.append(c)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }

    /// One CSV document, CRLF line endings, quoting only fields that need it.
    public static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
