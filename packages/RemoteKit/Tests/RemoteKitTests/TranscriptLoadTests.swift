import Testing

@testable import RemoteKit

/// A cold load lays the transcript over whatever the screen already
/// shows. Wrong here reads as a duplicated prompt or a vanished live
/// part, and only on the reload paths (foregrounding the phone, a watch
/// restarting) that nobody tests by hand.
@Suite("Transcript load")
struct TranscriptLoadTests {
    private func part(_ id: String, _ type: String = "text", text: String? = nil) -> TurnPart {
        TurnPart(type: type, id: id, text: text ?? id)
    }

    @Test("An empty screen takes the transcript as is")
    func coldStart() {
        let transcript = [part("a", "user"), part("b"), part("c")]
        #expect(TranscriptLoad.merge(transcript, into: []) == transcript)
    }

    @Test("The transcript wins on order and content for ids it carries")
    func transcriptIsAuthority() {
        let stale = TurnPart(type: "tool", id: "t", tool: "edit", status: "running")
        let fresh = TurnPart(type: "tool", id: "t", tool: "edit", status: "completed")
        let merged = TranscriptLoad.merge([part("a"), fresh], into: [stale, part("a")])
        #expect(merged == [part("a"), fresh])
    }

    @Test("Parts a watch delivered after the snapshot stay, after the transcript")
    func liveLeftoversFollow() {
        let live = part("live")
        let merged = TranscriptLoad.merge([part("a"), part("b")], into: [part("a"), live])
        #expect(merged == [part("a"), part("b"), live])
    }

    @Test("A locally added prompt is replaced by the transcript's copy of it")
    func localPromptDedupes() {
        let local = TurnPart(type: "user", text: "Fix the race")
        let echoed = TurnPart(type: "user", id: "u1", text: "Fix the race")
        let merged = TranscriptLoad.merge([echoed, part("x")], into: [local, part("x")])
        #expect(merged == [echoed, part("x")])
    }

    @Test("A locally added prompt the transcript lacks survives")
    func localPromptKept() {
        let local = TurnPart(type: "user", text: "Not sent yet")
        let merged = TranscriptLoad.merge([part("a")], into: [part("a"), local])
        #expect(merged == [part("a"), local])
    }

    @Test("Reapplying a growing newest-first buffer never duplicates")
    func progressiveBatchesAreIdempotent() {
        let full = (0..<40).map { part("p\($0)") }
        var rows: [TurnPart] = [part("live")]
        for cut in [16, 32, 40] {
            rows = TranscriptLoad.merge(Array(full.suffix(cut)), into: rows)
        }
        #expect(rows == full + [part("live")])
    }

    @Test("Batches are one screen, then doubling")
    func flushSchedule() {
        let flushes = (1...300).filter(TranscriptLoad.shouldFlush(after:))
        #expect(flushes == [16, 32, 64, 128, 256])
    }
}
