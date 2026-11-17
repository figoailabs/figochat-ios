import CryptoKit
import Foundation

/// AES-256-GCM encrypt/decrypt util. Every instance makes its own random 256-bit key, held only in memory,
/// and every `encrypt` call uses a fresh random nonce. Output is `<nonce base64>:<ciphertext+tag base64>`.
///
/// The SDK uses it to keep the realtime settings returned by `GET /api/v1/realtime/config` encrypted while
/// they sit in memory; they are decrypted only at the moment a thread channel is subscribed.
public final class FigoCrypto {
    private let key = SymmetricKey(size: .bits256)

    public init() {}

    public func encrypt(_ plainText: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plainText.utf8), using: key)
        let nonce = Data(sealed.nonce)
        return "\(nonce.base64EncodedString()):\((sealed.ciphertext + sealed.tag).base64EncodedString())"
    }

    public func decrypt(_ cipherText: String) throws -> String {
        let parts = cipherText.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let nonceData = Data(base64Encoded: String(parts[0])),
              let combined = Data(base64Encoded: String(parts[1])),
              combined.count >= 16
        else {
            throw FigoChatError("FigoCrypto: value is not in \"<iv>:<ciphertext>\" form.", code: "CRYPTO")
        }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: combined.prefix(combined.count - 16),
            tag: combined.suffix(16)
        )
        let plain = try AES.GCM.open(box, using: key)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw FigoChatError("FigoCrypto: decrypted value is not UTF-8.", code: "CRYPTO")
        }
        return text
    }
}
