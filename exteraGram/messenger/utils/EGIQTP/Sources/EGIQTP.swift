import EGConfig
import EGLogging
import CryptoKit
import Foundation
import MtProtoKit
import Postbox
import Security
import SwiftSignalKit
import TelegramApi


public struct EGIQTPResponse {
    public let status: Int
    public let value: String
}


private let egIqtpTokenPrefix = "sgsig.v1."
private let egIqtpTokenMinimumParts = 4
private let egIqtpTokenSeparator: Character = "."
private let egIqtpTokenMaxPastSkew: Int64 = 30
private let egIqtpTokenMaxFutureSkew: Int64 = 10 * 60
private let egIqtpApiVersion = 1

private func egBase64UrlEncode(_ data: Data) -> String {
    let egBase64 = data.base64EncodedString()
    return egBase64
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func makeIqtpQuery(_ method: String, _ args: [String] = []) -> String {
    let buildNumber = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] ?? ""
    let nonceLength = 16
    var bytes = [UInt8](repeating: 0, count: nonceLength)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        for index in 0..<bytes.count {
            bytes[index] = UInt8.random(in: 0...UInt8.max)
        }
    }
    let nonce = egBase64UrlEncode(Data(bytes)).replacingOccurrences(of: ":", with: "_")
    let queryArgs = [nonce] + args
    let baseQuery = "tp:\(egIqtpApiVersion):\(buildNumber):\(method)"
    if queryArgs.isEmpty {
        return baseQuery
    }
    return baseQuery + ":" + queryArgs.joined(separator: ":")
}

public func egIqtpQuery(engine: TelegramEngine, query: String, incompleteResults: Bool = false, staleCachedResults: Bool = false) -> Signal<EGIQTPResponse?, NoError> {
    let queryId = arc4random()
    func egVerifySignedAnswer(query: String, answer: String, peerId: PeerId) -> String? {
        func egBase64UrlDecode(_ value: String) -> Data? {
            var egBase64 = value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let egRemainder = egBase64.count % 4
            if egRemainder > 0 {
                egBase64 += String(repeating: "=", count: 4 - egRemainder)
            }
            return Data(base64Encoded: egBase64)
        }

        func egDecodePublicKey(_ value: String) -> Data? {
            if let egData = Data(base64Encoded: value) {
                return egData
            }
            return egBase64UrlDecode(value)
        }

        func egExtractSignedToken(from text: String) -> (payload: String, signature: String)? {
            guard let egRange = text.range(of: egIqtpTokenPrefix) else {
                return nil
            }
            let egTokenStart = text[egRange.lowerBound...]
            guard let egTokenPart = egTokenStart.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else {
                return nil
            }
            let egParts = egTokenPart.split(separator: egIqtpTokenSeparator, omittingEmptySubsequences: false)
            guard egParts.count >= egIqtpTokenMinimumParts else {
                return nil
            }
            guard egParts[0] == "sgsig", egParts[1] == "v1" else {
                return nil
            }
            return (payload: String(egParts[2]), signature: String(egParts[3]))
        }

        let egQueryParts = query.split(separator: ":", omittingEmptySubsequences: false)
        guard egQueryParts.count >= 4, egQueryParts[0] == "tp" else {
            EGLogger.shared.log("EGIQTP", "Missing IQTP query info")
            return nil
        }
        guard let egQueryVersion = Int(egQueryParts[1]), egQueryVersion == 1 else {
            EGLogger.shared.log("EGIQTP", "Unsupported IQTP version")
            return nil
        }
        let egQueryBuild = String(egQueryParts[2])
        let egQueryMethod = String(egQueryParts[3])
        let egQueryArgs = egQueryParts.count > 4 ? egQueryParts[4...].map { String($0) } : []
        guard let egNonce = egQueryArgs.first, !egNonce.isEmpty else {
            EGLogger.shared.log("EGIQTP", "Missing IQTP nonce")
            return nil
        }

        guard let egPublicKey = EG_CONFIG.publicKey, !egPublicKey.isEmpty else {
            EGLogger.shared.log("EGIQTP", "Missing public key")
            return nil
        }
        guard let egToken = egExtractSignedToken(from: answer) else {
            EGLogger.shared.log("EGIQTP", "Missing signed IQTP token")
            return nil
        }
        guard let egAnswerData = egBase64UrlDecode(egToken.payload) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer encoding")
            return nil
        }
        guard let egSignatureData = egBase64UrlDecode(egToken.signature) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP signature encoding")
            return nil
        }
        guard let egPublicKeyData = egDecodePublicKey(egPublicKey) else {
            EGLogger.shared.log("EGIQTP", "Invalid public key")
            return nil
        }
        guard let egSigningKey = try? Curve25519.Signing.PublicKey(rawRepresentation: egPublicKeyData) else {
            EGLogger.shared.log("EGIQTP", "Invalid public key bytes")
            return nil
        }
        guard egSigningKey.isValidSignature(egSignatureData, for: egAnswerData) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP signature")
            return nil
        }
        guard let egAnswerString = String(data: egAnswerData, encoding: .utf8) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer string")
            return nil
        }
        let egAnswerParts = egAnswerString.split(separator: ":", omittingEmptySubsequences: false)
        guard egAnswerParts.count == 8 else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer parts count")
            return nil
        }
        guard let egAnswerVersion = Int(egAnswerParts[0]), egAnswerVersion == 1 else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer version")
            return nil
        }
        let egAnswerMethod = String(egAnswerParts[1])
        guard egAnswerMethod == egQueryMethod else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer method")
            return nil
        }
        guard let egAnswerPeerId = Int64(egAnswerParts[2]) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer peer id")
            return nil
        }
        let egAnswerNonce = String(egAnswerParts[3])
        guard egAnswerNonce == egNonce else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer nonce")
            return nil
        }
        guard let egIat = Int64(egAnswerParts[4]), let egExp = Int64(egAnswerParts[5]) else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer timing")
            return nil
        }
        let egValue = String(egAnswerParts[6])
        let egAnswerBuild = String(egAnswerParts[7])
        guard egAnswerBuild == egQueryBuild else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer build number")
            return nil
        }
        let egNow = Int64(Date().timeIntervalSince1970)
        guard egExp >= egNow - egIqtpTokenMaxPastSkew else {
            EGLogger.shared.log("EGIQTP", "Expired IQTP answer")
            return nil
        }
        guard egExp <= egNow + egIqtpTokenMaxFutureSkew else {
            EGLogger.shared.log("EGIQTP", "IQTP answer exp too far in future")
            return nil
        }
        guard egIat <= egExp else {
            EGLogger.shared.log("EGIQTP", "Invalid IQTP answer timing order")
            return nil
        }
        let egCurrentPeerId = peerId.id._internalGetInt64Value()
        guard egAnswerPeerId == egCurrentPeerId else {
            EGLogger.shared.log("EGIQTP", "IQTP answer peer id mismatch")
            return nil
        }
        return egValue
    }
    #if DEBUG
    EGLogger.shared.log("EGIQTP", "[\(queryId)] Query: \(query)")
    #else
    EGLogger.shared.log("EGIQTP", "[\(queryId)] Query")
    #endif
    return engine.peers.resolvePeerByName(name: EG_CONFIG.botUsername, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(result) = result else {
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Failed to resolve peer \(EG_CONFIG.botUsername)")
                return .complete()
            }
            return .single(result)
        }
        |> mapToSignal { peer -> Signal<ChatContextResultCollection?, NoError> in
            guard let peer = peer else {
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Empty peer")
                return .single(nil)
            }
            return engine.messages.requestChatContextResults(IQTP: true, botId: peer.id, peerId: engine.account.peerId, query: query, offset: "", incompleteResults: incompleteResults, staleCachedResults: staleCachedResults)
            |> map { results -> ChatContextResultCollection? in
                return results?.results
            }
            |> `catch` { error -> Signal<ChatContextResultCollection?, NoError> in
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Failed to request inline results")
                return .single(nil)
            }
        }
        |> map { contextResult -> EGIQTPResponse? in
            guard let contextResult, let firstResult = contextResult.results.first else {
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Empty inline result")
                return nil
            }
            
            var t: String?
            if case let .text(text, _, _, _, _, _) = firstResult.message {
                t = text
            }

            guard let t else {
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Missing signed IQTP answer")
                return nil
            }
            let egValue: String
            if let egVerifiedValue = egVerifySignedAnswer(query: query, answer: t, peerId: engine.account.peerId) {
                egValue = egVerifiedValue
            } else {
                EGLogger.shared.log("EGIQTP", "[\(queryId)] Invalid signed IQTP token")
                return nil
            }

            var status = 400
            if let title = firstResult.title {
                status = Int(title) ?? 400
            }
            let response = EGIQTPResponse(status: status, value: egValue)
            EGLogger.shared.log("EGIQTP", "[\(queryId)] Response status: \(status)")
            return response
        }
}
