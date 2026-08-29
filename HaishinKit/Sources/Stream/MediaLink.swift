import CoreMedia
import Foundation

final actor MediaLink {
    static let capacity = 90
    static let duration: TimeInterval = 0.0
    // Clock-rate PLL: keeps jitter buffer stable despite source/local clock drift
    private static let targetBufferFrames = 7
    private static let pllGainGentle: Double = 0.003   // near target
    private static let pllGainAggressive: Double = 0.03 // critically low buffer
    private static let criticalBufferThreshold = 3

    var dequeue: AsyncStream<CMSampleBuffer> {
        AsyncStream { continutation in
            self.continutation = continutation
        }
    }
    private(set) var isRunning = false
    private var storage: TypedBlockQueue<CMSampleBuffer>?
    private var continutation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var duration: TimeInterval = MediaLink.duration
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode?
    private var enqueueCount = 0
    private var renderCount = 0
    private var lastDiagTime: TimeInterval = 0
    private var lastWallTime: TimeInterval = 0
    /// True while the jitter buffer is starving or the PLL is saturated, so
    /// recovery gets reported once instead of the episode trailing off.
    private var wasUnhealthy = false

    init() {
        do {
            storage = try .init(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if presentationTimeStampOrigin == .invalid {
            presentationTimeStampOrigin = sampleBuffer.presentationTimeStamp
            duration = -0.3 // jitter buffer head start (slightly larger for PLL stability)
        }
        enqueueCount += 1
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            HKDiagnostics.log("Video", "enqueue overflow, queued: \(enqueueCount)")
        }
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }

    private func getCurrentTime(_ timestamp: TimeInterval) -> TimeInterval {
        // Non-linear clock-rate PLL: keeps the jitter buffer near target depth.
        // Two zones prevent both gradual drift AND sudden stalls from causing stutter.
        let bufferLevel = enqueueCount - renderCount
        let error = bufferLevel - Self.targetBufferFrames
        let gain = bufferLevel < Self.criticalBufferThreshold
            ? Self.pllGainAggressive   // 10× stronger when buffer is dangerously low
            : Self.pllGainGentle
        let correction = 1.0 + Double(error) * gain
        // Clamp: allow up to 20% slowdown (recovery) but only 5% speedup
        let clampedCorrection = min(max(correction, 0.80), 1.05)
        defer {
            duration += timestamp * clampedCorrection
        }
        return duration
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        duration = -0.3
        lastWallTime = 0
        displayLink.startRunning()
        Task {
            for await tick in displayLink.updateFrames {
                // Yield to let pending enqueue() calls run
                await Task.yield()
                guard let storage else {
                    continue
                }
                // Compute elapsed time from absolute wall time.
                // With .bufferingNewest(1), ticks may be dropped; using
                // absolute time ensures the delta accounts for ALL elapsed time.
                let wallTime = tick.targetTimestamp
                let delta: TimeInterval
                if lastWallTime == 0 {
                    delta = 1.0 / 60.0  // first tick
                } else {
                    delta = wallTime - lastWallTime
                }
                lastWallTime = wallTime
                let currentTime = getCurrentTime(delta)
                var frameCount = 0
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    if first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds <= currentTime {
                        continutation?.yield(first)
                        frameCount += 1
                        renderCount += 1
                        _ = storage.dequeue()
                    } else {
                        break
                    }
                }
                // Jitter-buffer diagnostics.
                //
                // Report only when the buffer is actually in trouble, not
                // every 2 seconds regardless. This used to emit a line per 2 s
                // for the life of the session, which in a monitoring tool's
                // log crowded out the connection and decode events an operator
                // is looking for — and it was the only thing visible in
                // release builds, where everything else was #if DEBUG.
                //
                // "In trouble" means the buffer sits below the critical
                // threshold (about to underrun, aggressive correction) or the
                // rate correction has saturated, i.e. the PLL can no longer
                // keep up with clock drift. Recovery is reported once so the
                // log shows the episode closing rather than trailing off.
                if currentTime - lastDiagTime >= 2.0 {
                    let bl = enqueueCount - renderCount
                    let g = bl < Self.criticalBufferThreshold ? Self.pllGainAggressive : Self.pllGainGentle
                    let corr = min(max(1.0 + Double(bl - Self.targetBufferFrames) * g, 0.80), 1.05)
                    let saturated = corr <= 0.801 || corr >= 1.049
                    let starving = bl < Self.criticalBufferThreshold
                    if starving || saturated {
                        wasUnhealthy = true
                        HKDiagnostics.log(
                            "Video",
                            "jitter buffer \(starving ? "starving" : "rate-limited"): " +
                            "buf:\(bl)/\(Self.targetBufferFrames) " +
                            "pll:\(String(format: "%.3f", corr)) " +
                            "in:\(enqueueCount) out:\(renderCount)"
                        )
                    } else if wasUnhealthy {
                        wasUnhealthy = false
                        HKDiagnostics.log(
                            "Video",
                            "jitter buffer recovered: buf:\(bl)/\(Self.targetBufferFrames) " +
                            "pll:\(String(format: "%.3f", corr))"
                        )
                    }
                    lastDiagTime = currentTime
                }
            }
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        continutation = nil
        displayLink.stopRunning()
        presentationTimeStampOrigin = .invalid
        duration = Self.duration
        enqueueCount = 0
        renderCount = 0
        lastDiagTime = 0
        lastWallTime = 0
        try? storage?.reset()
        isRunning = false
    }
}
