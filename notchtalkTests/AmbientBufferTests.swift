import Testing
@testable import notchtalk

@MainActor
struct AmbientBufferTests {
    @Test func cutsTheNewestSamplesAcrossTheWrapPoint() {
        let buffer = AmbientBuffer(capacity: 10)
        buffer.append(Array(0...3))
        buffer.append(Array(4...8))
        buffer.append(Array(9...13))
        #expect(buffer.count == 10)
        #expect(buffer.last(10) == Array(4...13))
        #expect(buffer.last(6) == Array(8...13))
        #expect(buffer.last(3) == [11, 12, 13])
        #expect(buffer.last(0) == [])
    }

    @Test func asksForMoreThanIsHeldGetsWhatIsThere() {
        let buffer = AmbientBuffer(capacity: 10)
        buffer.append([0, 1, 2])
        #expect(buffer.last(10) == [0, 1, 2])
        #expect(buffer.duration == 3.0 / Double(AmbientBuffer.sampleRate))
    }

    @Test func oversizedChunkKeepsOnlyItsTail() {
        let buffer = AmbientBuffer(capacity: 10)
        buffer.append(Array(0..<25))
        #expect(buffer.count == 10)
        #expect(buffer.last(10) == Array(15..<25))
    }

    @Test func resizingKeepsTheNewestAudio() {
        let buffer = AmbientBuffer(capacity: 10)
        buffer.append(Array(0..<14))
        buffer.resize(capacity: 4)
        #expect(buffer.last(4) == Array(10..<14))
        buffer.resize(capacity: 8)
        #expect(buffer.count == 4)
        buffer.append([14])
        #expect(buffer.last(8) == Array(10...14))
    }

    @Test func turningAmbientOffDiscardsTheWindow() {
        let recorder = AmbientRecorder()
        recorder.buffer.resize(capacity: 100)
        recorder.buffer.append(Array(0..<100))
        recorder.update(enabled: false, windowMinutes: 10)
        #expect(recorder.buffer.count == 0)
        #expect(recorder.buffer.capacity == 1)
        #expect(recorder.buffer.last(100) == [])
        recorder.buffer.append([7])
        #expect(recorder.buffer.last(100) == [7])
    }
}
