import Foundation

enum SkillUsageLineReaderError: Error {
    case invalidUTF8
}

/// Reads a log incrementally so a large history file never has to fit in memory.
///
/// `String(contentsOf:)` would allocate the entire file. This reader keeps only the current
/// 64 KB chunk plus the unfinished line, which bounds memory by the longest single JSONL line.
enum SkillUsageLineReader {
    static func forEachLine(
        at url: URL,
        chunkSize: Int = 64 * 1024,
        _ body: (String) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let lineData = buffer[lineStart..<newline]
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw SkillUsageLineReaderError.invalidUTF8
                }
                body(line)
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if !buffer.isEmpty {
            guard let line = String(data: buffer, encoding: .utf8) else {
                throw SkillUsageLineReaderError.invalidUTF8
            }
            body(line)
        }
    }
}
