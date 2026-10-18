import Foundation

/// Where the tailer is in events.jsonl. `inode` detects rotation/replacement.
public struct TailCursor: Codable, Equatable, Sendable {
    public var offset: UInt64
    public var inode: UInt64?

    public init(offset: UInt64 = 0, inode: UInt64? = nil) {
        self.offset = offset
        self.inode = inode
    }
}

/// Reads complete lines appended since a cursor. A trailing partial line (a write in
/// progress) is left unread and picked up on the next call.
public enum EventFileReader {
    public struct Result: Sendable {
        public var lines: [Data]
        /// File offset just past each line (its newline included), for consumers that
        /// commit progress line by line (the Mongo sync).
        public var lineEnds: [UInt64]
        public var cursor: TailCursor
        /// True if the file was replaced or truncated and reading restarted at 0.
        public var rotated: Bool
    }

    public static let maxChunk = 4 * 1024 * 1024

    public static func readNewLines(path: String, cursor: TailCursor) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return Result(lines: [], lineEnds: [], cursor: cursor, rotated: false) }
        let attrs = try fm.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value

        var cursor = cursor
        var rotated = false
        if (cursor.inode != nil && inode != cursor.inode) || size < cursor.offset {
            cursor.offset = 0
            rotated = true
        }
        cursor.inode = inode
        guard size > cursor.offset else { return Result(lines: [], lineEnds: [], cursor: cursor, rotated: rotated) }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.read(upToCount: maxChunk) ?? Data()

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Result(lines: [], lineEnds: [], cursor: cursor, rotated: rotated)
        }
        let complete = data[data.startIndex...lastNewline]
        var lines: [Data] = []
        var lineEnds: [UInt64] = []
        var start = complete.startIndex
        while let newline = complete[start...].firstIndex(of: 0x0A) {
            if newline > start {
                lines.append(Data(complete[start..<newline]))
                lineEnds.append(cursor.offset + UInt64(newline + 1 - complete.startIndex))
            }
            start = newline + 1
        }
        cursor.offset += UInt64(complete.count)
        return Result(lines: lines, lineEnds: lineEnds, cursor: cursor, rotated: rotated)
    }

    /// Complete lines after `cursor` (from 0 if the file was replaced or truncated).
    public static func countLines(path: String, after cursor: TailCursor) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return 0 }
        defer { try? handle.close() }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let replaced = (cursor.inode != nil && inode != cursor.inode) || size < cursor.offset
        var count = 0
        do {
            try handle.seek(toOffset: replaced ? 0 : cursor.offset)
            while let chunk = try handle.read(upToCount: maxChunk), !chunk.isEmpty {
                count += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            }
        } catch {
            return count
        }
        return count
    }
}
