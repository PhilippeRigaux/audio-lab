import Foundation

final class FloatRingBuffer {
    private let channels: Int
    private let capacityFrames: Int
    private var storage: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private let lock = NSLock()

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(1, capacityFrames)
        self.channels = max(1, channels)
        self.storage = Array(repeating: 0, count: self.capacityFrames * self.channels)
    }

    func write(_ input: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        var frameCount = frames
        var source = input
        if frameCount > capacityFrames {
            source = source.advanced(by: (frameCount - capacityFrames) * channels)
            frameCount = capacityFrames
        }

        let overflow = max(0, availableFrames + frameCount - capacityFrames)
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacityFrames
            availableFrames -= overflow
        }

        let firstChunkFrames = min(frameCount, capacityFrames - writeIndex)
        copyFrames(from: source, toFrame: writeIndex, frames: firstChunkFrames)

        let remainingFrames = frameCount - firstChunkFrames
        if remainingFrames > 0 {
            copyFrames(from: source.advanced(by: firstChunkFrames * channels), toFrame: 0, frames: remainingFrames)
        }

        writeIndex = (writeIndex + frameCount) % capacityFrames
        availableFrames += frameCount
    }

    func read(_ output: UnsafeMutablePointer<Float>, frames: Int, fillRemainingWithZero: Bool = true) -> Int {
        guard frames > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let framesToRead = min(frames, availableFrames)
        if framesToRead > 0 {
            let firstChunkFrames = min(framesToRead, capacityFrames - readIndex)
            copyFrames(fromFrame: readIndex, to: output, frames: firstChunkFrames)

            let remainingFrames = framesToRead - firstChunkFrames
            if remainingFrames > 0 {
                copyFrames(fromFrame: 0, to: output.advanced(by: firstChunkFrames * channels), frames: remainingFrames)
            }

            readIndex = (readIndex + framesToRead) % capacityFrames
            availableFrames -= framesToRead
        }

        if fillRemainingWithZero, framesToRead < frames {
            let start = framesToRead * channels
            let end = frames * channels
            for index in start..<end {
                output[index] = 0
            }
        }

        return framesToRead
    }

    func availableFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return availableFrames
    }

    @discardableResult
    func discard(frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let dropped = min(frames, availableFrames)
        readIndex = (readIndex + dropped) % capacityFrames
        availableFrames -= dropped
        return dropped
    }

    private func copyFrames(from source: UnsafePointer<Float>, toFrame destinationFrame: Int, frames: Int) {
        guard frames > 0 else { return }
        let sampleCount = frames * channels
        storage.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            let destination = dstBase.advanced(by: destinationFrame * channels)
            destination.update(from: source, count: sampleCount)
        }
    }

    private func copyFrames(fromFrame sourceFrame: Int, to destination: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sampleCount = frames * channels
        storage.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            let source = srcBase.advanced(by: sourceFrame * channels)
            destination.update(from: source, count: sampleCount)
        }
    }
}
