import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var passthrough = true
    var outputStream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var invalidateSession = true
    private var presentationTimeStamp: CMTime = .zero
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            invalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            if invalidateSession {
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
            }
            guard let session, let continuation else {
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    try session.convert(sampleBuffer, continuation: continuation)
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                }
            }
        } catch {
            logger.warn(error)
            // Also surface it to the host app. `logger` goes to HaishinKit's
            // internal Logboard sink, which the app never sees — so a
            // VideoToolbox failure (bad SPS/PPS, unsupported profile, a
            // corrupt access unit) produced a black picture with nothing
            // logged anywhere the operator could find it. Rate-limited
            // because a broken stream fails per frame.
            videoDecodeErrors += 1
            if videoDecodeErrors == 1 || videoDecodeErrors % 100 == 0 {
                HKDiagnostics.log(
                    "Error",
                    "Video decode failed (\(videoDecodeErrors) total): \(error) " +
                    "[compressed=\(sampleBuffer.formatDescription?.isCompressed == true)]"
                )
            }
        }
    }

    /// Count of `append` failures, used to rate-limit the diagnostic above.
    private var videoDecodeErrors = 0

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - self.presentationTimeStamp.seconds
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        invalidateSession = true
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = .zero
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
