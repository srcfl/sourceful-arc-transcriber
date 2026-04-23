import Foundation
import Combine

/// Holds the Arc access token and the user's display email across
/// launches. The token is written to Keychain; the email is derived
/// from the JWT payload (unverified — purely for UI) and cached
/// alongside so the Settings label renders immediately on launch
/// without an API round-trip.
@MainActor
final class ArcAuthStore: ObservableObject {
    @Published private(set) var token: String?
    @Published private(set) var userEmail: String?

    private static let tokenAccount = "arc-access-token"
    private static let emailAccount = "arc-user-email"

    init() {
        self.token = Keychain.load(account: Self.tokenAccount)
        self.userEmail = Keychain.load(account: Self.emailAccount)
    }

    var isSignedIn: Bool { token != nil }

    func save(token: String) {
        try? Keychain.save(token, account: Self.tokenAccount)
        self.token = token

        if let email = Self.extractEmail(from: token) {
            try? Keychain.save(email, account: Self.emailAccount)
            self.userEmail = email
        }
    }

    func signOut() {
        Keychain.delete(account: Self.tokenAccount)
        Keychain.delete(account: Self.emailAccount)
        token = nil
        userEmail = nil
    }

    /// JWT payload is base64url-encoded; we only read `email`, so no
    /// signature verification needed — the server validates the token
    /// on every API call.
    private static func extractEmail(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let email = dict["email"] as? String else { return nil }
        return email
    }
}
