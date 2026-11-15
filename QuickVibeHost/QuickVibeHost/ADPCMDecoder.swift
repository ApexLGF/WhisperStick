import Foundation

/// IMA-ADPCM decoder matching the firmware encoder in QuickVibeStickS3
struct ADPCMDecoder {
    private static let stepTable: [Int16] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]

    private static let indexTable: [Int8] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    var prevSample: Int16 = 0
    var index: Int8 = 0

    mutating func reset() {
        prevSample = 0
        index = 0
    }

    /// Decode a single 4-bit ADPCM code to a 16-bit PCM sample
    private mutating func decodeSample(_ code: UInt8) -> Int16 {
        let step = Int(Self.stepTable[Int(index)])
        var diffq = step >> 3
        if code & 4 != 0 { diffq += step }
        if code & 2 != 0 { diffq += step >> 1 }
        if code & 1 != 0 { diffq += step >> 2 }

        var sample = Int(prevSample)
        if code & 8 != 0 {
            sample -= diffq
        } else {
            sample += diffq
        }
        sample = max(-32768, min(32767, sample))
        prevSample = Int16(sample)

        var newIndex = Int(index) + Int(Self.indexTable[Int(code & 0x0F)])
        newIndex = max(0, min(88, newIndex))
        index = Int8(newIndex)

        return prevSample
    }

    /// Decode ADPCM bytes to PCM Int16 samples
    /// Each byte contains 2 ADPCM samples (low nibble first, high nibble second)
    mutating func decode(_ adpcmData: Data) -> [Int16] {
        var pcm: [Int16] = []
        pcm.reserveCapacity(adpcmData.count * 2)

        for byte in adpcmData {
            let low = byte & 0x0F
            let high = (byte >> 4) & 0x0F
            pcm.append(decodeSample(low))
            pcm.append(decodeSample(high))
        }

        return pcm
    }
}
