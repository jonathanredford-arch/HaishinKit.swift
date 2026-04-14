import Combine
import Foundation
import HaishinKit
import libsrt

// MARK: - SRTDataObserver Protocol

/// Protocol for observing raw MPEG-TS data received over SRT.
/// Implement this to analyze transport stream packets before decoding.
public protocol SRTDataObserver: AnyObject, Sendable {
    /// Called when raw MPEG-TS data is received from the SRT connection.
    /// - Parameters:
    ///   - connection: The SRT connection that received the data.
    ///   - data: Raw MPEG-TS transport stream data.
    func srtConnection(_ connection: SRTConnection, didReceive data: Data)
}

/// An actor that provides the interface to control a SRT connection.
///
/// Supports a one-to-one connection. Multiple connections cannot be established.
public actor SRTConnection: NetworkConnection {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The uri isn't supported.
        case unsupportedUri(_ uri: URL?)
        /// The failed to connect.
        case failedToConnect(_ reason: SRTRejectReason)
    }

    /// The SRT Library version.
    public static let version: String = SRT_VERSION_STRING
    /// The URI passed to the `connect()` method.
    public private(set) var uri: URL?
    /// This instance connect to server(true) or not(false)
    @Published public private(set) var connected = false
    /// The performance data.
    public var performanceData: SRTPerformanceData? {
        get async {
            return await socket?.performanceData
        }
    }
    
    /// Observer for raw MPEG-TS data. Set this to receive transport stream packets for analysis.
    public weak var dataObserver: (any SRTDataObserver)?
    
    /// Sets the data observer for receiving raw MPEG-TS packets.
    public func setDataObserver(_ observer: (any SRTDataObserver)?) {
        self.dataObserver = observer
    }

    private var socket: SRTSocket?
    private var streams: [SRTStream] = []
    private var listener: SRTSocket?
    private var networkMonitor: NetworkMonitor?

    /// Creates an object.
    public init() {
        srt_startup()
        socket = SRTSocket()
    }

    deinit {
        streams.removeAll()
        srt_cleanup()
    }

    /// Gets a SRTSocketOption.
    public func getSocketOption(_ name: SRTSocketOption.Name) async throws -> SRTSocketOption? {
        try await socket?.getSocketOption(name)
    }

    /// Sets a SRTSocketOption.
    public func setSocketOption(_ option: SRTSocketOption) async throws {
        if connected {
            guard option.name.restriction == .post else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        } else {
            guard option.name.restriction == .pre else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        }
    }

    /// Creates a connection to the server or waits for an incoming connection.
    ///
    /// - Parameters:
    ///   - uri: You can specify connection options in the URL. This follows the standard SRT format.
    ///
    /// - srt://192.168.1.1:9000?mode=caller
    ///   - Connect to the specified server.
    /// - srt://:9000?mode=listener
    ///   - Wait for connections as a server.
    public func connect(_ uri: URL?) async throws {
        guard let url = SRTSocketURL(uri) else {
            throw Error.unsupportedUri(uri)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                Task {
                    do {
                        try await socket?.open(url)
                        self.uri = uri
                        switch url.mode {
                        case .caller:
                            break
                        case .listener:
                            listener = socket
                            socket = try await listener?.accept(url.options)
                            await listener?.stopRunning()
                            listener = nil
                        case .rendezvous:
                            break
                        }
                        connected = await socket?.status == .connected
                        continuation.resume()
                    } catch {
                        socket = SRTSocket()
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task {
                guard let socket else {
                    return
                }
                let networkMonitor = await socket.makeNetworkMonitor()
                self.networkMonitor = networkMonitor
                await networkMonitor.startRunning()
                for await event in await networkMonitor.event {
                    for stream in streams {
                        await stream.dispatch(event)
                    }
                }
            }
        } catch let error as SRTSocket.Error {
            switch error {
            case .rejected(let reason):
                throw Error.failedToConnect(reason)
            default:
                throw Error.invalidState
            }
        } catch {
            throw Error.invalidState
        }
    }

    /// Closes a connection.
    public func close() async {
        guard uri != nil else {
            return
        }
        await networkMonitor?.stopRunning()
        networkMonitor = nil
        for stream in streams {
            await stream.close()
        }
        await socket?.stopRunning()
        socket = nil
        await listener?.stopRunning()
        listener = nil
        uri = nil
        connected = false
        socket = SRTSocket()
    }

    func send(_ data: Data) async {
        do {
            try await socket?.send(data)
        } catch {
            await close()
        }
    }

    func recv() {
        Task { [weak self] in
            guard let self, let socket = await self.socket else {
                return
            }
            for await data in await socket.inputs {
                // Capture observer reference safely
                let observer = await self.dataObserver
                // Notify observer of raw TS data before decoding (on a detached task to avoid actor isolation issues)
                if let observer {
                    Task.detached { [data] in
                        observer.srtConnection(self, didReceive: data)
                    }
                }
                // Pass to stream for decoding
                await self.streams.first?.doInput(data)
            }
            await self.close()
        }
    }

    func addStream(_ stream: SRTStream) {
        guard !streams.contains(where: { $0 === stream }) else {
            return
        }
        streams.append(stream)
    }

    func removeStream(_ stream: SRTStream) {
        if let index = streams.firstIndex(where: { $0 === stream }) {
            streams.remove(at: index)
        }
    }
}
