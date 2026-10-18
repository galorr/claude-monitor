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
        public var cursor: TailCursor
        /// True if the file was replaced or truncated and reading restarted at 0.
        public var rotated: Bool
    }

    public static let maxChunk = 4 * 1024 * 1024

    public static func readNewLines(path: String, cursor: TailCursor) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return Result(lines: [], cursor: cursor, rotated: false) }
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
        guard size > cursor.offset else { return Result(lines: [], cursor: cursor, rotated: rotated) }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.read(upToCount: maxChunk) ?? Data()

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Result(lines: [], cursor: cursor, rotated: rotated)
        }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        cursor.offset += UInt64(complete.count)
        return Result(lines: lines, cursor: cursor, rotated: rotated)
    }
}
