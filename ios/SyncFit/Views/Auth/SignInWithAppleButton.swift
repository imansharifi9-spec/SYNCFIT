import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit

struct SignInWithAppleButton: UIViewRepresentable {
    var style: ASAuthorizationAppleIDButton.Style
    var isEnabled: Bool
    var onCompletion: (Result<(ASAuthorization, String), Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
        button.cornerRadius = 14
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleAuthorization),
            for: .touchUpInside
        )
        button.isUserInteractionEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.5
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        uiView.isUserInteractionEnabled = isEnabled
        uiView.alpha = isEnabled ? 1 : 0.5
    }

    final class Coordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        private let onCompletion: (Result<(ASAuthorization, String), Error>) -> Void
        private var currentNonce: String?

        init(onCompletion: @escaping (Result<(ASAuthorization, String), Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        @objc func handleAuthorization() {
            let nonce = Self.randomNonceString()
            currentNonce = nonce

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            guard let nonce = currentNonce else {
                onCompletion(.failure(AppleSignInError.missingNonce))
                return
            }
            onCompletion(.success((authorization, nonce)))
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithError error: Error
        ) {
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            onCompletion(.failure(error))
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes
                .first(where: { $0.activationState == .foregroundActive })?
                .windows
                .first(where: \.isKeyWindow)
                ?? scenes.first?.windows.first(where: \.isKeyWindow)
            return window ?? ASPresentationAnchor()
        }

        private static func randomNonceString(length: Int = 32) -> String {
            precondition(length > 0)
            var randomBytes = [UInt8](repeating: 0, count: length)
            let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            if errorCode != errSecSuccess {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
            }

            let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
            return String(randomBytes.map { charset[Int($0) % charset.count] })
        }

        private static func sha256(_ input: String) -> String {
            let inputData = Data(input.utf8)
            let hashedData = SHA256.hash(data: inputData)
            return hashedData.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
}

private enum AppleSignInError: LocalizedError {
    case missingNonce

    var errorDescription: String? {
        switch self {
        case .missingNonce:
            return "Apple sign-in failed. Try again."
        }
    }
}
