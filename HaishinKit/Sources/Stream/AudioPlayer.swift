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
            HKDiagnostics.log("Audio", "Connecting node, format: \(format)")
            audioEngine.connect(avPlayerNode, to: audioEngine.outputNode, format: format)
            if !audioEngine.isRunning {
                do {
                    #if os(iOS) || os(tvOS) || os(visionOS)
                    let session = AVAudioSession.sharedInstance()
                    if !session.isOtherAudioPlaying {
                        try session.setActive(true)
                    }
                    HKDiagnostics.log("Engine", "Session active: \(session.isOtherAudioPlaying == false), category: \(session.category.rawValue), sampleRate: \(session.sampleRate)")
                    #endif
                    try audioEngine.start()
                    HKDiagnostics.log("Engine", "Audio engine started, outputFormat: \(audioEngine.outputNode.outputFormat(forBus: 0))")
                } catch {
                    HKDiagnostics.log("Error", "Audio engine failed to start: \(error)")
                }
            }
            connected[playerNode] = true
            HKDiagnostics.log("Audio", "Node connected, engine isRunning: \(audioEngine.isRunning)")
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
