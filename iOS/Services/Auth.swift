import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign in with Apple nonce: Apple gets the SHA-256 hash, Supabase gets the raw value and checks they match.
struct AppleNonce {
    let raw: String

    init() {
        var g = SystemRandomNumberGenerator()  // cryptographically secure on Apple platforms
        raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sign in with Apple, then Supabase (`BackupController.signIn`), which starts the restore.
struct AppleSignInButton: View {
    let backup: BackupController
    @State private var nonce = AppleNonce()
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var height = 50.0

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = AppleNonce()
            request.nonce = nonce.hashed
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential
                let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
                let raw = nonce.raw
                Task { await backup.signIn(idToken: token, nonce: raw) }
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure:
                Task { await backup.signIn(idToken: nil, nonce: "") }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: height)
        .accessibilityHint("Signs in to back up your workouts and restore them on a new phone.")
    }
}
