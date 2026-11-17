import Foundation

/// Keeps a sorted array of UTF-16 offsets where each line starts, updated incrementally
/// on every edit so line/column lookups stay O(log n) even for very large files.
final class LineIndex {
    private(set) var starts: [Int] = [0]

    var lineCount: Int { starts.count }

    /// Offset of the first character of a 0-based line.
    func lineStart(_ line: Int) -> Int {
        starts[max(0, min(line, starts.count - 1))]
    }

    /// 0-based line containing the given UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        max(0, upperBound(offset) - 1)
    }

    /// Update after a text storage edit. `editedRange` is in post-edit coordinates.
    func applyEdit(editedRange: NSRange, changeInLength delta: Int, text: NSString) {
        let loc = editedRange.location
        let oldUpper = loc + editedRange.length - delta
        let lo = upperBound(loc)
        let hi = upperBound(oldUpper)

        var inserted: [Int] = []
        Self.collectLineStarts(in: text, range: editedRange, into: &inserted)

        if delta != 0 && hi < starts.count {
            starts.withUnsafeMutableBufferPointer { buf in
                for i in hi..<buf.count { buf[i] += delta }
            }
        }
        starts.replaceSubrange(lo..<hi, with: inserted)
        if starts.isEmpty || starts[0] != 0 { starts.insert(0, at: 0) }
    }

    func rebuild(_ text: NSString) {
        var s = [0]
        Self.collectLineStarts(in: text, range: NSRange(location: 0, length: text.length), into: &s)
        starts = s
    }

    private func upperBound(_ value: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func collectLineStarts(in s: NSString, range: NSRange, into arr: inout [Int]) {
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var pos = range.location
        let end = NSMaxRange(range)
        while pos < end {
            let len = min(chunk, end - pos)
            let base = pos
            buffer.withUnsafeMutableBufferPointer { bp in
                s.getCharacters(bp.baseAddress!, range: NSRange(location: base, length: len))
                for i in 0..<len where bp[i] == 10 {
                    arr.append(base + i + 1)
                }
            }
            pos += len
        }
    }
}
