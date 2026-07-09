import CryptoKit
import Foundation

enum CoachAuthCrypto {
    static func sha256Hex(_ input: String) -> String {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Stable local coach profile ID derived from a Firebase Auth UID.
    static func stableCoachUUID(from firebaseUID: String) -> UUID {
        let digest = SHA256.hash(data: Data(firebaseUID.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}

#if DEBUG
enum CoachDevSeed {
    /// SHA-256 hash of the dev access code — stored hashed in Firestore, never plain text.
    static let devCodeHash = "689fa0845119d7122d0ba9d8eafffc5a8e9ae616e13ffc3c187aade4956794e8"

    static func isDevCoachCode(_ plainCode: String) -> Bool {
        CoachAuthCrypto.sha256Hex(plainCode) == devCodeHash
    }
}
#endif
