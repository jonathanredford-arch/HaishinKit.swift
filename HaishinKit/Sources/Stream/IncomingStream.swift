@preconcurrency import AVFoundation
import Foundation

/// An actor that provides a stream playback feature.
package final actor IncomingStream {
    public private(set) var isRunning = false
    /// The sound transform value control.
    public var soundTransfrom: SoundTransform? {
        get async {
            return await audioPlayerNode?.soundTransfrom
        }
    }
    private lazy var mediaLink = MediaLink()
    private lazy var audioCodec = AudioCodec()
    private lazy var videoCodec = VideoCodec()
    private weak var stream: (any StreamConvertible)?
    private var audioPlayerNode: AudioPlayerNode?

    /// Creates a new instance.
    public init(_ stream: some StreamConvertible) {
        self.stream = stream
    }

    /// Sets the sound transform value control.
    public func setSoundTransform(_ soundTransfrom: SoundTransform) async {
        await audioPlayerNode?.setSoundTransfrom(soundTransfrom)
    }

    /// Appends a sample buffer for playback.
    public func append(_ buffer: CMSampleBuffer) {
        switch buffer.formatDescription?.mediaType {
        case .audio:
            if !loggedFirstAudioAppend {
                loggedFirstAudioAppend = true
                HKDiagnostics.log("Audio", "first audio sample buffer reached the codec")
            }
            audioCodec.append(buffer)
        case .video:
            videoCodec.append(buffer)
        default:
            // Neither audio nor video, which in practice means the sample
            // buffer has no format description. Silently discarding these is
            // how audio disappears without a trace.
            droppedUnclassified += 1
            if droppedUnclassified == 1 || droppedUnclassified % 200 == 0 {
                HKDiagnostics.log(
                    "Error",
                    "dropped \(droppedUnclassified) sample buffer(s) with no usable "
                    + "format description (mediaType "
                    + "\(buffer.formatDescription.map { "\($0.mediaType)" } ?? "nil"))")
            }
        }
    }

    private var loggedFirstAudioAppend = false
    private var droppedUnclassified = 0

    /// Appends an audio buffer for playback.
    public func append(_ buffer: AVAudioBuffer, when: AVAudioTime) {
        audioCodec.append(buffer, when: when)
    }

    /// Attaches an audio player.
    public func attachAudioPlayer(_ audioPlayer: AudioPlayer?) async {
        await audioPlayerNode?.detach()
        audioPlayerNode = await audioPlayer?.makePlayerNode()
        await mediaLink.setAudioPlayer(audioPlayerNode)
    }
}

extension IncomingStream: AsyncRunner {
    // MARK: AsyncRunner
    public func startRunning() {
        guard !isRunning else {
            return
        }
        audioCodec.settings.format = .pcm
        videoCodec.startRunning()
        audioCodec.startRunning()
        isRunning = true
        Task {
            await mediaLink.startRunning()
            for await video in await mediaLink.dequeue {
                await stream?.append(video)
            }
        }
        Task {
            for await video in videoCodec.outputStream {
                await mediaLink.enqueue(video)
            }
        }
        Task {
            if audioPlayerNode == nil {
                // The player node is created by attachAudioPlayer. If the
                // runner starts first there is nothing to start, and every
                // decoded buffer below is sent to a nil optional — audio is
                // decoded and then thrown away in silence.
                HKDiagnostics.log(
                    "Error",
                    "audio runner started with no player node attached — "
                    + "attachAudioPlayer must be called before play()")
            }
            await audioPlayerNode?.startRunning()
            var decoded = 0
            for await audio in audioCodec.outputStream {
                decoded += 1
                if decoded == 1 {
                    HKDiagnostics.log(
                        "Audio",
                        "first decoded audio buffer from the codec"
                        + (audioPlayerNode == nil ? " — but no player node, discarding" : ""))
                }
                await audioPlayerNode?.enqueue(audio.0, when: audio.1)
            }
        }
    }

    public func stopRunning() {
        guard isRunning else {
            return
        }
        videoCodec.stopRunning()
        audioCodec.stopRunning()
        Task { await mediaLink.stopRunning() }
        Task { await audioPlayerNode?.stopRunning() }
        isRunning = false
    }
}
