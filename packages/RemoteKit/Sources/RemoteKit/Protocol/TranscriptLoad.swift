import Foundation

/// How a client folds a loaded transcript into the rows it already shows.
///
/// A transcript answer is not applied part by part: on a long thread that
/// is thousands of view updates and an animated scroll for each, which is
/// the minute of watching history crawl past that this replaces. The
/// parts are collected and merged in a few batches instead, tail first
/// when the Mac can send them that way, so the newest screen paints at
/// once and the rest fills in above it.
public enum TranscriptLoad {
    /// The transcript in reading order, laid over the rows on screen.
    ///
    /// The transcript is the authority on order and, for any id it
    /// carries, on content: it is the newer snapshot, the same rule the
    /// live upsert follows. Rows it doesn't mention survive after it, in
    /// their own order; those are parts a watch delivered since the
    /// snapshot was taken. A prompt the client added itself, before the
    /// Mac had given it an id, is recognised by its text and replaced by
    /// the transcript's copy rather than kept as a second bubble.
    public static func merge(_ transcript: [TurnPart], into rows: [TurnPart]) -> [TurnPart] {
        let ids = Set(transcript.compactMap(\.id))
        let prompts = Set(transcript.filter { $0.type == "user" }.compactMap(\.text))
        let leftovers = rows.filter { row in
            if let id = row.id { return !ids.contains(id) }
            if row.type == "user", let text = row.text { return !prompts.contains(text) }
            return !transcript.contains(row)
        }
        return transcript + leftovers
    }

    /// Whether a newest-first load should paint after `received` parts.
    ///
    /// The first batch is one screen's worth, so the user is reading
    /// while the rest is still on the wire; after that the batches
    /// double, so the number of view updates stays logarithmic in the
    /// length of the thread. The caller flushes once more when the
    /// stream ends, whatever the count.
    public static func shouldFlush(after received: Int) -> Bool {
        received >= firstBatch && (received & (received - 1)) == 0
    }

    /// Enough parts to fill a phone screen and then some.
    public static let firstBatch = 16
}
