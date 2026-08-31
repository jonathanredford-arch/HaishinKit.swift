import CoreMedia
import Foundation
import HaishinKit

enum ESStreamType: UInt8 {
    case unspecific = 0x00
    case mpeg1Video = 0x01
    case mpeg2Video = 0x02
    case mpeg1Audio = 0x03
    case mpeg2Audio = 0x04
    case mpeg2TabledData = 0x05
    case mpeg2PacketizedData = 0x06

    case adtsAac = 0x0F
    case h263 = 0x10

    case h264 = 0x1B
    case h265 = 0x24

    var headerSize: Int {
        switch self {
        case .adtsAac:
            return 7
        default:
            return 0
        }
    }
}

struct ESSpecificData: Equatable {
    static let fixedHeaderSize: Int = 5

    var streamType: ESStreamType = .unspecific
    var elementaryPID: UInt16 = 0
    var esInfoLength: UInt16 = 0
    var esDescriptors = Data()

    init() {
    }

    init?(_ data: Data) {
        self.data = data
    }
}

extension ESSpecificData: DataConvertible {
    // MARK: DataConvertible
    var data: Data {
        get {
            ByteArray()
                .writeUInt8(streamType.rawValue)
                .writeUInt16(elementaryPID | 0xe000)
                .writeUInt16(esInfoLength | 0xf000)
                .writeBytes(esDescriptors)
                .data
        }
        set {
            let buffer = ByteArray(data: newValue)
            do {
                streamType = ESStreamType(rawValue: try buffer.readUInt8()) ?? .unspecific
                // elementary_PID is 13 bits (ISO/IEC 13818-1 Table 2-33), so
                // the mask is 0x1FFF. It was 0x0FFF, which silently truncated
                // every PID at or above 0x1000: a live stream carrying audio
                // on PID 0x1010 was read as 0x10, no packets ever arrived on
                // that PID, and the audio simply never played. Video on PID
                // 0x200 was unaffected, so the stream looked half-broken with
                // nothing in any log to explain it.
                //
                // The sibling parsers in TSProgram.swift already use 0x1FFF
                // for program_map_PID and PCR_PID, which is what makes this a
                // typo rather than a deliberate limit.
                elementaryPID = try buffer.readUInt16() & 0x1fff
                // ES_info_length is 12 bits, not 9. The old 0x01FF mask only
                // mattered for descriptor blocks of 512 bytes or more, where
                // it would truncate the length and then misalign the read.
                esInfoLength = try buffer.readUInt16() & 0x0fff
                esDescriptors = try buffer.readBytes(Int(esInfoLength))
            } catch {
                logger.error("\(buffer)")
            }
        }
    }
}

extension ESSpecificData: CustomDebugStringConvertible {
    // MARK: CustomDebugStringConvertible
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}
