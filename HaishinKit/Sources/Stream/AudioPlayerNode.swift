@preconcurrency import AVFoundation
import Foundation

final actor AudioPlayerNode {
    static let bufferCounts: Int = 10

    var currentTime: TimeInterval {
        if playerNode.isPlaying {
            guard
                let nodeTime = playerNode.lastRenderTime,
                let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return 0.0
            }
            return TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        }
        return 0.0
    }
    private(set) var isPaused = false
    private(set) var isRunning = false
    private(set) var soundTransfrom = SoundTransform()
    private let playerNode: AVAudioPlayerNode
    private var audioTime = AudioTime()
    private var scheduledAudioBuffers: Int = 0
    private var isBuffering = true
    private weak var player: AudioPlayer?
    private var format: AVAudioFormat?

    init(player: AudioPlayer, playerNode: AVAudioPlayerNode) {
        self.player = player
        self.playerNode = playerNode
    }

    func setSoundTransfrom(_ soundTransfrom: SoundTransform) {
        soundTransfrom.apply(playerNode)
    }

    func enqueue(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) async {
        if format != audioBuffer.format {
            format = audioBuffer.format
            HKDiagnostics.log("Audio", "Format changed: \(audioBuffer.format)")
            await player?.connect(self, format: format)
        }
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer, await player?.isConnected(self) == true else {
            return
        }
        scheduledAudioBuffers += 1
        if !isPaused && !playerNode.isPlaying && Self.bufferCounts <= scheduledAudioBuffers {
            playerNode.play()
            HKDiagnostics.log("Audio", "playerNode.play() called, scheduled: \(scheduledAudioBuffers)")
        }
        // Use synchronous scheduleBuffer — the async overload creates a Task that
        // lives until the buffer finishes *playing*, accumulating thousands of
        // concurrent Tasks over minutes that contend on this actor and starve
        // the decode pipeline.
        playerNode.scheduleBuffer(audioBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { [weak self] in
                await self?.onBufferPlayedBack()
            }
        }
    }

    private func onBufferPlayedBack() {
        scheduledAudioBuffers -= 1
        if scheduledAudioBuffers == 0 {
            isBuffering = true
        }
    }

    func detach() async {
        stopRunning()
        await player?.detach(self)
    }
}

extension AudioPlayerNode: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        scheduledAudioBuffers = 0
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if playerNode.isPlaying {
            playerNode.stop()
            playerNode.reset()
        }
        audioTime.reset()
        if format != nil {
            format = nil
            Task { [weak self] in
                guard let self else { return }
                await player?.connect(self, format: nil)
            }
        }
        isRunning = false
    }
}

extension AudioPlayerNode: Hashable {
    // MARK: Hashable
    nonisolated public static func == (lhs: AudioPlayerNode, rhs: AudioPlayerNode) -> Bool {
        lhs === rhs
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
