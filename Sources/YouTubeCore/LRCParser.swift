import Foundation

// MARK: - LRC
//
// Three of the five sources hand back LRC ("[01:00.28] Open your mouth wide"),
// so parsing it once here keeps the providers to request-shaping.

public enum LRCParser {

    /// Parses an LRC document into timed lines, sorted by time.
    ///
    /// Handles the parts of the format that appear in the wild:
    ///  - `[mm:ss.xx]`, `[mm:ss.xxx]` and `[mm:ss]` timestamps;
    ///  - several timestamps on one line (a repeated chorus);
    ///  - `[ar:]`/`[ti:]`/`[by:]` metadata tags, which are dropped;
    ///  - blank timed lines, which are kept — they are the gaps between verses
    ///    and dropping them makes the highlight jump early.
    public static func parse(_ document: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        // NetEase/Musixmatch documents show up CRLF; splitting on "\n" alone
        // (like `parsePlain` normalizes for but this did not) left a trailing
        // "\r" on every line, and `.whitespaces` in `split(_:)`'s trim below
        // does not include it — poisoning both rendering and every
        // similarity/agreement comparison downstream.
        let document = document.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let (times, text) = split(String(raw))
            guard !times.isEmpty else { continue }
            for time in times {
                lines.append(LyricLine(text: text, start: time))
            }
        }
        return lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    /// Splits one LRC line into its timestamps and its text.
    /// Returns no timestamps for a metadata tag or an untimed line.
    static func split(_ raw: String) -> (times: [TimeInterval], text: String) {
        var times: [TimeInterval] = []
        var remainder = Substring(raw)

        while remainder.hasPrefix("[") {
            guard let close = remainder.firstIndex(of: "]") else { break }
            let tag = remainder[remainder.index(after: remainder.startIndex)..<close]
            guard let time = timestamp(tag) else {
                // A metadata tag ([ar:…]) at the head: the whole line is metadata.
                if tag.contains(":"), tag.first?.isNumber == false { return ([], "") }
                break
            }
            times.append(time)
            remainder = remainder[remainder.index(after: close)...]
        }

        return (times, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `mm:ss.xx` → seconds. Returns nil for anything that is not a timestamp.
    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]), !parts[0].isEmpty else { return nil }

        let secondsPart = parts[1]
        let pieces = secondsPart.split(separator: ".", omittingEmptySubsequences: false)
        guard let seconds = Int(pieces[0]), pieces.count <= 2 else { return nil }

        var fraction: TimeInterval = 0
        if pieces.count == 2, let hundredths = Int(pieces[1]) {
            // Both [mm:ss.xx] and [mm:ss.xxx] occur; scale by digit count.
            fraction = TimeInterval(hundredths) / pow(10, Double(pieces[1].count))
        }
        return TimeInterval(minutes * 60 + seconds) + fraction
    }

    /// Splits plain (untimed) lyrics into lines, dropping the leading and
    /// trailing blank runs but keeping the blank lines between verses.
    public static func parsePlain(_ text: String) -> [LyricLine] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LyricLine(text: String($0).trimmingCharacters(in: .whitespaces)) }
        while lines.first?.text.isEmpty == true { lines.removeFirst() }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Attaches a romanised LRC track to an already-parsed native one.
    ///
    /// The two documents share timestamps (NetEase generates them together) but
    /// not always line counts, so lines are paired by nearest timestamp within
    /// a small window rather than by index.
    public static func merge(romanized: [LyricLine], into native: [LyricLine]) -> [LyricLine] {
        guard !romanized.isEmpty else { return native }
        var result = native
        for index in result.indices {
            guard let start = result[index].start else { continue }
            let match = romanized.min {
                abs(($0.start ?? .infinity) - start) < abs(($1.start ?? .infinity) - start)
            }
            guard let match, let matchStart = match.start, abs(matchStart - start) < 0.5,
                  !match.text.isEmpty, match.text != result[index].text else { continue }
            result[index].romanized = match.text
        }
        return result
    }
}
