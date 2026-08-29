@preconcurrency import AVFoundation

/// An object that provides the interface to control audio playback.
public final actor AudioPlayer {
    private var connected: [AudioPlayerNode: Bool] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNodes: [AudioPlayerNode: AVAudioPlayerNode] = [:]

    /// Create an audio player object.
    public init(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    func isConnected(_ playerNode: AudioPlayerNode) -> Bool {
        return connected[playerNode] == true
    }

    func connect(_ playerNode: AudioPlayerNode, format: AVAudioFormat?) {
        guard let audioEngine, let avPlayerNode = playerNodes[playerNode] else {
            HKDiagnostics.log("Audio", "connect() — engine or playerNode missing")
            return
        }
        if let format {
            audioEngine.connect(avPlayerNode, to: audioEngine.outputNode, format: format)
            var startError: String?
            if !audioEngine.isRunning {
                do {
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    let session = AVAudioSession.sharedInstance()
                    if !session.isOtherAudioPlaying {
                        try session.setActive(true)
                    }
                    #endif
                    try audioEngine.start()
                } catch {
                    startError = "\(error)"
                    HKDiagnostics.log("Error", "Audio engine failed to start: \(error)")
                }
            }
            connected[playerNode] = true
            // One line instead of the four this used to emit. Reports the
            // negotiated formats on both sides of the connection, which is
            // the first thing to check when audio is missing or wrong: a
            // stream/engine sample-rate or channel-count mismatch is the
            // usual cause, and it is invisible without both numbers.
            if startError == nil {
                let out = audioEngine.outputNode.outputFormat(forBus: 0)
                HKDiagnostics.log(
                    "Audio",
                    "running — stream \(Int(format.sampleRate)) Hz "
                    + "\(format.channelCount)ch → engine \(Int(out.sampleRate)) Hz "
                    + "\(out.channelCount)ch, engine isRunning: \(audioEngine.isRunning)"
                )
            }
        } else {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.disconnectNodeOutput(avPlayerNode)
            connected[playerNode] = nil
            HKDiagnostics.log("Audio", "Node disconnected")
        }
    }

    func detach(_ playerNode: AudioPlayerNode) {
        if let playerNode = playerNodes[playerNode] {
            audioEngine?.detach(playerNode)
        }
        playerNodes[playerNode] = nil
    }

    func makePlayerNode() -> AudioPlayerNode {
        let avAudioPlayerNode = AVAudioPlayerNode()
        audioEngine?.attach(avAudioPlayerNode)
        let playerNode = AudioPlayerNode(player: self, playerNode: avAudioPlayerNode)
        playerNodes[playerNode] = avAudioPlayerNode
        return playerNode
    }
}
