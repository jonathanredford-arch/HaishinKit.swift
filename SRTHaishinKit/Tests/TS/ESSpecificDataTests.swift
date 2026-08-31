import CoreMedia
import Foundation
import Testing

@testable import SRTHaishinKit

@Suite struct ESSpecificDataTests {
    private let AACData = Data([15, 225, 1, 240, 6, 10, 4, 117, 110, 100, 0])
    private let H264Data = Data([27, 225, 0, 240, 0, 15, 225, 1, 240, 6, 10, 4, 117, 110, 100, 0])

    @Test func readAACData() {
        let data = ESSpecificData(AACData)
        #expect(data?.streamType == .adtsAac)
        #expect(data?.elementaryPID == 257)
    }

    @Test func readH264Data() {
        let data = ESSpecificData(H264Data)
        #expect(data?.streamType == .h264)
        #expect(data?.elementaryPID == 256)
    }

    /// elementary_PID is 13 bits, so values at or above 0x1000 must survive.
    ///
    /// Regression: the mask was 0x0FFF, so a live stream carrying AAC on PID
    /// 0x1010 was read as 0x10. No packets ever arrived on that PID and the
    /// audio never played, while video on PID 0x200 was unaffected — a
    /// half-working stream with nothing in the logs. Both existing cases
    /// above use PIDs below 0x1000, which is why this went unnoticed.
    @Test func readsThirteenBitElementaryPID() {
        // 0x0F = adtsAac, then 0xF010 = reserved bits set + PID 0x1010.
        let data = ESSpecificData(Data([0x0F, 0xF0, 0x10, 0xF0, 0x00]))
        #expect(data?.streamType == .adtsAac)
        #expect(data?.elementaryPID == 0x1010)
    }

    @Test func readsTheHighestLegalPID() {
        // 0x1FFF is the null-packet PID and the maximum a 13-bit field holds.
        let data = ESSpecificData(Data([0x1B, 0xFF, 0xFF, 0xF0, 0x00]))
        #expect(data?.elementaryPID == 0x1FFF)
    }

    /// ES_info_length is 12 bits. The old 0x01FF mask truncated any
    /// descriptor block of 512 bytes or more and then misaligned the read.
    @Test func readsTwelveBitESInfoLength() {
        let descriptorCount = 0x250          // 592 bytes, over the old limit
        var bytes: [UInt8] = [0x0F, 0xE1, 0x01]
        bytes += [0xF0 | UInt8(descriptorCount >> 8), UInt8(descriptorCount & 0xFF)]
        bytes += [UInt8](repeating: 0x00, count: descriptorCount)
        let data = ESSpecificData(Data(bytes))
        #expect(data?.esInfoLength == UInt16(descriptorCount))
        #expect(data?.esDescriptors.count == descriptorCount)
    }
}
