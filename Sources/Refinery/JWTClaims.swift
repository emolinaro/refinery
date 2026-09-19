import Foundation

/// Minimal JWT claims reader used only for non-secret, client-side state:
/// token expiry (to schedule refresh) and the id_token's account profile
/// (email, plan) for the Settings account line. Never validates signatures:
/// OpenAI's servers are the authority for every accepted request.
struct JWTClaims {
    struct Identity: Equatable, Sendable {
        var email: String?
        var planType: String?
    }

    let subject: String?
    let expiration: Date?
    let issuedAt: Date?
    let identity: Identity

    enum DecodeError: Error {
        case malformed
    }

    init(subject: String?, expiration: Date?, issuedAt: Date?, identity: Identity) {
        self.subject = subject
        self.expiration = expiration
        self.issuedAt = issuedAt
        self.identity = identity
    }

    /// Decodes the unverified payload of a compact JWS. The signature is
    /// never inspected and never leaves this type.
    static func decode(_ token: String) throws -> JWTClaims {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw DecodeError.malformed }
        var base64 = String(parts[1])
        // JWT uses base64url without padding.
        base64 = base64.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let payload = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw DecodeError.malformed
        }

        let expiration = (json["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        let issuedAt = (json["iat"] as? Double).map(Date.init(timeIntervalSince1970:))
        let subject = json["sub"] as? String

        var email = json["email"] as? String
        var planType: String?
        if let auth = json["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
            if email == nil {
                email = auth["email"] as? String
            }
        }
        return JWTClaims(
            subject: subject,
            expiration: expiration,
            issuedAt: issuedAt,
            identity: Identity(email: email, planType: planType)
        )
    }
}
