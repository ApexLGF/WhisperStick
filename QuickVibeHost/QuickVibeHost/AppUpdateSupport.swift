import Foundation
import CryptoKit

enum MicStickOTAProtocolError: Error {
    case invalidFrame
    case invalidValue
}

struct MicStickOTABegin: Equatable {
    let schema: UInt8
    let hardware: UInt8
    let protocolVersion: UInt8
    let version: String
    let imageSize: UInt32
    let sha256: Data
    let signature: Data
    let resumeOffset: UInt32
}

struct MicStickOTADataFrame: Equatable {
    let offset: UInt32
    let payload: Data
}

enum MicStickOTAState: UInt8, Equatable {
    case idle = 0
    case prepared = 1
    case receiving = 2
    case validating = 3
    case rebootPending = 4
    case rebooted = 5
    case confirmed = 6
}

enum MicStickOTAError: UInt8, Equatable {
    case none = 0
    case badFrame = 1
    case incompatible = 2
    case badState = 3
    case badOffset = 4
    case tooLarge = 5
    case sha256 = 6
    case signature = 7
    case flash = 8
}

struct MicStickOTAInfo: Equatable {
    let schema: UInt8
    let product: String
    let hardware: UInt8
    let protocolVersion: UInt8
    let state: MicStickOTAState
    let version: String
}

struct MicStickOTAStatus: Equatable {
    let state: MicStickOTAState
    let acceptedOffset: UInt32
    let error: MicStickOTAError
}

enum MicStickOTAProtocol {
    static let infoRequest: UInt8 = 0x01
    static let begin: UInt8 = 0x02
    static let finish: UInt8 = 0x03
    static let abort: UInt8 = 0x04
    static let beginFragment: UInt8 = 0x05
    static let infoResponse: UInt8 = 0x81
    static let status: UInt8 = 0x82

    static func encodeBegin(_ value: MicStickOTABegin) throws -> Data {
        let versionData = Data(value.version.utf8)
        guard versionData.count <= 31,
              value.sha256.count == 32,
              value.signature.count <= Int(UInt16.max) else {
            throw MicStickOTAProtocolError.invalidValue
        }

        var data = Data([begin, value.schema, value.hardware, value.protocolVersion])
        data.append(UInt8(versionData.count))
        data.append(versionData)
        appendUInt32(value.imageSize, to: &data)
        data.append(value.sha256)
        appendUInt16(UInt16(value.signature.count), to: &data)
        data.append(value.signature)
        appendUInt32(value.resumeOffset, to: &data)
        return data
    }

    static func decodeBegin(_ data: Data) throws -> MicStickOTABegin {
        guard data.count >= 1 + 3 + 1 + 4 + 32 + 2 + 4,
              data.first == begin else {
            throw MicStickOTAProtocolError.invalidFrame
        }

        var index = 1
        let schema = try readByte(data, index: &index)
        let hardware = try readByte(data, index: &index)
        let protocolVersion = try readByte(data, index: &index)
        let version = try readString(data, index: &index, maximumLength: 31)
        let imageSize = try readUInt32(data, index: &index)
        let sha256 = try readData(data, index: &index, count: 32)
        let signatureLength = Int(try readUInt16(data, index: &index))
        let signature = try readData(data, index: &index, count: signatureLength)
        let resumeOffset = try readUInt32(data, index: &index)
        guard index == data.count else { throw MicStickOTAProtocolError.invalidFrame }

        return MicStickOTABegin(
            schema: schema,
            hardware: hardware,
            protocolVersion: protocolVersion,
            version: version,
            imageSize: imageSize,
            sha256: sha256,
            signature: signature,
            resumeOffset: resumeOffset
        )
    }

    static func decodeData(_ data: Data) throws -> MicStickOTADataFrame {
        guard data.count >= 5 else { throw MicStickOTAProtocolError.invalidFrame }
        var index = 0
        let offset = try readUInt32(data, index: &index)
        let payload = try readData(data, index: &index, count: data.count - index)
        guard !payload.isEmpty else { throw MicStickOTAProtocolError.invalidFrame }
        return MicStickOTADataFrame(offset: offset, payload: payload)
    }

    static func encodeInfo(_ value: MicStickOTAInfo) throws -> Data {
        let productData = Data(value.product.utf8)
        let versionData = Data(value.version.utf8)
        guard productData.count <= 31, versionData.count <= 31 else {
            throw MicStickOTAProtocolError.invalidValue
        }
        var data = Data([infoResponse, value.schema, UInt8(productData.count)])
        data.append(productData)
        data.append(contentsOf: [value.hardware, value.protocolVersion, value.state.rawValue])
        data.append(UInt8(versionData.count))
        data.append(versionData)
        return data
    }

    static func decodeInfo(_ data: Data) throws -> MicStickOTAInfo {
        guard data.count >= 1 + 1 + 1 + 3 + 1, data.first == infoResponse else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        var index = 1
        let schema = try readByte(data, index: &index)
        let product = try readString(data, index: &index, maximumLength: 31)
        let hardware = try readByte(data, index: &index)
        let protocolVersion = try readByte(data, index: &index)
        guard let state = MicStickOTAState(rawValue: try readByte(data, index: &index)) else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        let version = try readString(data, index: &index, maximumLength: 31)
        guard index == data.count else { throw MicStickOTAProtocolError.invalidFrame }
        return MicStickOTAInfo(
            schema: schema,
            product: product,
            hardware: hardware,
            protocolVersion: protocolVersion,
            state: state,
            version: version
        )
    }

    static func encodeStatus(_ value: MicStickOTAStatus) -> Data {
        var data = Data([status, value.state.rawValue])
        appendUInt32(value.acceptedOffset, to: &data)
        data.append(value.error.rawValue)
        return data
    }

    static func decodeStatus(_ data: Data) throws -> MicStickOTAStatus {
        guard data.count == 7, data.first == status else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        var index = 1
        guard let state = MicStickOTAState(rawValue: try readByte(data, index: &index)) else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        let acceptedOffset = try readUInt32(data, index: &index)
        guard let error = MicStickOTAError(rawValue: try readByte(data, index: &index)) else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        return MicStickOTAStatus(state: state, acceptedOffset: acceptedOffset, error: error)
    }

    static func encodeBeginFragments(
        _ value: MicStickOTABegin,
        maximumLength: Int
    ) throws -> [Data] {
        let frame = try encodeBegin(value)
        if frame.count <= maximumLength { return [frame] }
        guard maximumLength >= 7 else { throw MicStickOTAProtocolError.invalidValue }
        let payloadLength = maximumLength - 5
        let fragmentCount = (frame.count + payloadLength - 1) / payloadLength
        guard fragmentCount <= Int(UInt16.max) else {
            throw MicStickOTAProtocolError.invalidValue
        }
        return stride(from: 0, to: frame.count, by: payloadLength).enumerated().map {
            index, offset in
            let end = min(offset + payloadLength, frame.count)
            var fragment = Data([beginFragment])
            appendUInt16(UInt16(index), to: &fragment)
            appendUInt16(UInt16(fragmentCount), to: &fragment)
            fragment.append(frame[offset..<end])
            return fragment
        }
    }

    static func decodeBeginFragment(
        _ data: Data
    ) throws -> (index: UInt16, count: UInt16, payload: Data) {
        guard data.count >= 6, data.first == beginFragment else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        var index = 1
        let fragmentIndex = try readUInt16(data, index: &index)
        let fragmentCount = try readUInt16(data, index: &index)
        guard fragmentCount > 0, fragmentIndex < fragmentCount else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        let payload = try readData(data, index: &index, count: data.count - index)
        guard !payload.isEmpty, index == data.count else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        return (fragmentIndex, fragmentCount, payload)
    }

    @discardableResult
    static func decodeControl(_ data: Data) throws -> UInt8 {
        guard let opcode = data.first else { throw MicStickOTAProtocolError.invalidFrame }
        switch opcode {
        case infoRequest, finish, abort:
            guard data.count == 1 else { throw MicStickOTAProtocolError.invalidFrame }
        case begin:
            _ = try decodeBegin(data)
        case beginFragment:
            _ = try decodeBeginFragment(data)
        default:
            throw MicStickOTAProtocolError.invalidFrame
        }
        return opcode
    }

    private static func readByte(_ data: Data, index: inout Int) throws -> UInt8 {
        guard index < data.count else { throw MicStickOTAProtocolError.invalidFrame }
        defer { index += 1 }
        return data[index]
    }

    private static func readUInt16(_ data: Data, index: inout Int) throws -> UInt16 {
        let low = UInt16(try readByte(data, index: &index))
        let high = UInt16(try readByte(data, index: &index))
        return low | (high << 8)
    }

    private static func readUInt32(_ data: Data, index: inout Int) throws -> UInt32 {
        let b0 = UInt32(try readByte(data, index: &index))
        let b1 = UInt32(try readByte(data, index: &index))
        let b2 = UInt32(try readByte(data, index: &index))
        let b3 = UInt32(try readByte(data, index: &index))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readData(_ data: Data, index: inout Int, count: Int) throws -> Data {
        guard count >= 0, index <= data.count, count <= data.count - index else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        defer { index += count }
        return data.subdata(in: index..<(index + count))
    }

    private static func readString(
        _ data: Data,
        index: inout Int,
        maximumLength: Int
    ) throws -> String {
        let count = Int(try readByte(data, index: &index))
        guard count <= maximumLength else { throw MicStickOTAProtocolError.invalidFrame }
        let bytes = try readData(data, index: &index, count: count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw MicStickOTAProtocolError.invalidFrame
        }
        return value
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

struct AppVersion: Comparable, Codable, CustomStringConvertible {
    private let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }
        components = parts.map { Int($0)! }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid app version: \(value)"
            )
        }
        self = version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

struct AppRelease: Decodable {
    let latest: AppVersion
    let minSupported: AppVersion
    let downloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case latest
        case minSupported = "min_supported"
        case downloadURL = "download_url"
    }
}

struct AppUpdateManifest: Decodable {
    let schema: Int
    let app: AppRelease

    static func decode(_ data: Data) throws -> AppUpdateManifest {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

enum AppUpdateStorage {
    static let updatesDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("QuickVibeHost/Updates", isDirectory: true)
}

enum MicStickOTAResumePolicy {
    static func canResume(target: UUID?, connected: UUID?) -> Bool {
        guard let target, let connected else { return false }
        return target == connected
    }

    static func allowsManualDisconnect(state: MicStickFirmwareUpdateState) -> Bool {
        state != .downloading && !state.isActive
    }

    static func stateAfterServiceDiscovery(
        _ state: MicStickFirmwareUpdateState,
        hasOTAService: Bool
    ) -> MicStickFirmwareUpdateState {
        state.isActive && !hasOTAService ? .failed : state
    }

    static func stateAfterCharacteristicDiscovery(
        _ state: MicStickFirmwareUpdateState,
        hasRequiredCharacteristics: Bool
    ) -> MicStickFirmwareUpdateState {
        state.isActive && !hasRequiredCharacteristics ? .failed : state
    }

    static func canResumeAfterFinish(deviceState: MicStickOTAState) -> Bool {
        deviceState == .prepared || deviceState == .receiving
    }

    static func stateAfterBadOffset(_ state: MicStickFirmwareUpdateState)
        -> MicStickFirmwareUpdateState {
        state == .waitingForReboot ? .transferring : state
    }
}

enum MicStickOTADownloadPolicy {
    static func canCommit(state: MicStickFirmwareUpdateState, taskCancelled: Bool) -> Bool {
        !taskCancelled && state == .downloading
    }
}

struct MicStickOTAAbortState: Equatable {
    private(set) var targetPeripheralID: UUID?

    var isPending: Bool {
        targetPeripheralID != nil
    }

    func blocksTransfer(for peripheralID: UUID?) -> Bool {
        guard let targetPeripheralID else { return false }
        return targetPeripheralID == peripheralID
    }

    mutating func request(for targetPeripheralID: UUID?) {
        guard let targetPeripheralID else { return }
        self.targetPeripheralID = targetPeripheralID
    }

    mutating func consumeIfPending(connected: UUID?) -> Bool {
        guard let targetPeripheralID,
              connected == targetPeripheralID else { return false }
        self.targetPeripheralID = nil
        return true
    }
}

struct MicStickFirmwareRelease: Decodable {
    let latest: AppVersion
    let protocolVersion: UInt8
    let minApp: AppVersion
    let hardwareRevision: UInt8
    let ota: OTAArtifact?
    let flashURL: URL

    struct OTAArtifact: Decodable {
        let url: URL
        let size: Int64
        let sha256: String
        let signatureURL: URL

        enum CodingKeys: String, CodingKey {
            case url, size, sha256
            case signatureURL = "signature_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case latest
        case protocolVersion = "protocol"
        case minApp = "min_app"
        case hardwareRevision = "hardware_revision"
        case ota
        case flashURL = "flash_url"
    }

    static func isCompatible(
        _ release: MicStickFirmwareRelease,
        product: String,
        hardware: UInt8,
        protocol protocolVersion: UInt8,
        currentVersion: AppVersion,
        currentApp: AppVersion
    ) -> Bool {
        guard product == "micstick",
              hardware == release.hardwareRevision,
              protocolVersion == release.protocolVersion,
              hardware == 14,
              release.protocolVersion == 5,
              currentApp >= release.minApp,
              release.latest > currentVersion,
              let ota = release.ota,
              ota.size > 0,
              isFirmwarePath(ota.url),
              isFirmwarePath(ota.signatureURL),
              isLowercaseSHA256(ota.sha256) else {
            return false
        }
        return true
    }

    private static func isFirmwarePath(_ url: URL) -> Bool {
        url.scheme == nil && url.host == nil && url.port == nil &&
        url.query == nil && url.fragment == nil &&
        url.path.hasPrefix("/firmware/micstick/") &&
        !url.path.split(separator: "/").contains("..")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct MicStickCompatibilityManifest: Decodable {
    let firmware: [String: MicStickFirmwareRelease]
}

enum MicStickFirmwareUpdateState: Equatable {
    case unavailable
    case checking
    case available
    case downloading
    case transferring
    case waitingForReboot
    case verifying
    case succeeded
    case cancelled
    case failed

    var isActive: Bool {
        switch self {
        case .downloading, .transferring, .waitingForReboot, .verifying:
            return true
        default:
            return false
        }
    }
}

enum MicStickOTAHardwareCompatibility {
    /// V14 v1.2.0 reports hardware 14 in INFO but its OTA receiver still
    /// validates BEGIN against the legacy hard-coded value 12. Limit the
    /// compatibility value to that one bootstrap release; fixed firmware must
    /// receive the real hardware revision.
    static func metadataHardware(deviceHardware: UInt8, currentVersion: String) -> UInt8 {
        deviceHardware == 14 && currentVersion == "1.2.0" ? 12 : deviceHardware
    }
}

enum MicStickOTABootVerificationPolicy {
    static let stableIdleDelayNanoseconds: UInt64 = 8_000_000_000

    /// A confirmed state is authoritative. Some V14 builds expose the newly
    /// booted target as idle instead, so accept idle only after a delayed,
    /// explicit re-read proves that the target stayed connected and stable.
    static func acceptsTarget(state: MicStickOTAState, afterStableIdleRead: Bool) -> Bool {
        state == .confirmed || (state == .idle && afterStableIdleRead)
    }
}

struct MicStickOTATransferWindow: Equatable {
    private(set) var acknowledgedOffset: Int
    private(set) var sendOffset: Int
    private var endOffset: Int

    init(startOffset: Int) {
        acknowledgedOffset = startOffset
        sendOffset = startOffset
        endOffset = startOffset
    }

    var canStartNextWindow: Bool {
        acknowledgedOffset >= endOffset
    }

    mutating func markSent(_ offset: Int) {
        guard offset >= sendOffset else { return }
        sendOffset = offset
        endOffset = max(endOffset, offset)
    }

    mutating func acknowledge(_ offset: Int) {
        acknowledgedOffset = min(max(acknowledgedOffset, offset), sendOffset)
    }

    mutating func rewind(to offset: Int) {
        acknowledgedOffset = offset
        sendOffset = offset
        endOffset = offset
    }
}

struct MicStickOTARetryPolicy: Equatable {
    private(set) var timeoutRetries = 0
    static let maxTimeoutRetries = 3

    mutating func recordTimeout() -> Bool {
        guard timeoutRetries < Self.maxTimeoutRetries else { return false }
        timeoutRetries += 1
        return true
    }

    mutating func reset() {
        timeoutRetries = 0
    }
}

enum MicStickOTAFileVerifier {
    enum VerificationError: Error {
        case invalidMetadata
        case sizeMismatch
        case hashMismatch
        case invalidSignature
    }

    private static let publicKey = Data([
        0x04, 0x51, 0xa2, 0xe4, 0x40, 0xe2, 0xd0, 0x6d,
        0x91, 0x21, 0x33, 0xa3, 0xde, 0x8d, 0x04, 0x7c,
        0x1e, 0x45, 0x38, 0xb2, 0x87, 0x5b, 0x3e, 0xf9,
        0x44, 0x37, 0x13, 0x0f, 0x4c, 0x41, 0xc9, 0x44,
        0xe1, 0xf2, 0xbf, 0x66, 0xd6, 0x77, 0x6c, 0x79,
        0x7a, 0x2a, 0x35, 0x87, 0xd1, 0x44, 0x63, 0x17,
        0x4d, 0x85, 0x02, 0x87, 0xb6, 0x53, 0xb7, 0x63,
        0x4f, 0x7a, 0x5d, 0xb2, 0x34, 0xcd, 0x53, 0x4c,
        0xa9
    ])

    static func sha256Hex(at url: URL) throws -> String {
        try sha256Digest(at: url).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(
        imageURL: URL,
        expectedSize: Int64,
        expectedSHA256: String,
        signature: Data
    ) throws {
        guard expectedSize > 0, isLowercaseSHA256(expectedSHA256) else {
            throw VerificationError.invalidMetadata
        }
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == expectedSize else {
            throw VerificationError.sizeMismatch
        }

        let digest = try sha256Digest(at: imageURL)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw VerificationError.hashMismatch }

        do {
            let key = try P256.Signing.PublicKey(rawRepresentation: Data(publicKey.dropFirst()))
            let parsedSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
            guard key.isValidSignature(parsedSignature, for: digest) else {
                throw VerificationError.invalidSignature
            }
        } catch let error as VerificationError {
            throw error
        } catch {
            throw VerificationError.invalidSignature
        }
    }

    private static func sha256Digest(at url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
