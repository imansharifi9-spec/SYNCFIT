import AuthenticationServices
import Foundation
import FirebaseAuth
import GoogleSignIn
import UIKit

@MainActor
final class AuthenticationManager: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var hasResolvedInitialAuthState = false
    @Published private(set) var clearedStaleSession = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var isLoading = false

    private static let hasLaunchedBeforeKey = "com.syncfit.app.hasLaunchedBefore"

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var hasValidatedInitialSession = false

    init() {
        startIfNeeded()
    }

    static func prepareForFreshInstallIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: hasLaunchedBeforeKey) else { return false }
        clearPersistedSignInSessions()
        clearLastAuthenticatedUserID()
        UserDefaults.standard.set(true, forKey: hasLaunchedBeforeKey)
        return true
    }

    static let lastAuthenticatedUserIDKey = "com.syncfit.app.lastAuthenticatedUserID"

    static var lastAuthenticatedUserID: String? {
        get { UserDefaults.standard.string(forKey: lastAuthenticatedUserIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastAuthenticatedUserIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastAuthenticatedUserIDKey)
            }
        }
    }

    static func clearLastAuthenticatedUserID() {
        UserDefaults.standard.removeObject(forKey: lastAuthenticatedUserIDKey)
    }

    static func clearPersistedSignInSessions() {
        guard FirebaseConfiguration.isConfigured else { return }
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    func acknowledgeSessionClear() {
        clearedStaleSession = false
    }

    func startIfNeeded() {
        guard authStateHandle == nil else { return }

        guard FirebaseConfiguration.isConfigured else {
            user = nil
            isAuthenticated = false
            hasResolvedInitialAuthState = true
            return
        }

        listenForAuthState()
    }

    deinit {
        guard FirebaseConfiguration.isConfigured, let authStateHandle else { return }
        Auth.auth().removeStateDidChangeListener(authStateHandle)
    }

    func signUp(email: String, password: String) async {
        guard FirebaseConfiguration.isConfigured else {
            errorMessage = firebaseNotConfiguredMessage
            return
        }
        await authenticate(context: .emailPassword) {
            try await Auth.auth().createUser(withEmail: email, password: password)
        }
    }

    func signIn(email: String, password: String) async {
        guard FirebaseConfiguration.isConfigured else {
            errorMessage = firebaseNotConfiguredMessage
            return
        }
        await authenticate(context: .emailPassword) {
            try await Auth.auth().signIn(withEmail: email, password: password)
        }
    }

    func sendPasswordReset(email: String) async {
        guard FirebaseConfiguration.isConfigured else {
            errorMessage = firebaseNotConfiguredMessage
            return
        }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter your email address first."
            infoMessage = nil
            return
        }
        guard trimmed.contains("@"), trimmed.contains(".") else {
            errorMessage = "Enter a valid email address."
            infoMessage = nil
            return
        }

        errorMessage = nil
        infoMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await Auth.auth().sendPasswordReset(withEmail: trimmed)
            infoMessage = "Check your email for a link to reset your password."
        } catch {
            infoMessage = nil
            errorMessage = friendlyAuthError(error, context: .passwordReset)
        }
    }

    func signInWithApple(authorization: ASAuthorization, nonce: String) async {
        guard FirebaseConfiguration.isConfigured else {
            errorMessage = firebaseNotConfiguredMessage
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = appleIDCredential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            errorMessage = "Apple sign-in failed. Try again."
            return
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )

        do {
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            handleAuthFailure(error, context: .oauth)
        }
    }

    func signInWithGoogle() async {
        guard FirebaseConfiguration.isConfigured else {
            errorMessage = firebaseNotConfiguredMessage
            return
        }
        guard let presenter = Self.presentationViewController() else {
            errorMessage = "Unable to present Google sign-in."
            return
        }

        FirebaseConfiguration.configureGoogleSignInIfNeeded()

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Google sign-in failed. Try again."
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            if isGoogleSignInCancellation(error) {
                return
            }
            handleAuthFailure(error, context: .oauth)
        }
    }

    func signOut() {
        errorMessage = nil
        infoMessage = nil
        guard FirebaseConfiguration.isConfigured else { return }
        GIDSignIn.sharedInstance.signOut()
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = friendlyAuthError(error, context: .general)
        }
    }

    private enum AuthErrorContext {
        case general
        case emailPassword
        case oauth
        case sessionRecovery
        case passwordReset
    }

    private var firebaseNotConfiguredMessage: String {
        "Firebase is not configured. Add GoogleService-Info.plist to the SyncFit target."
    }

    private func authenticate(
        context: AuthErrorContext,
        _ action: () async throws -> AuthDataResult
    ) async {
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await action()
        } catch {
            handleAuthFailure(error, context: context)
        }
    }

    private func listenForAuthState() {
        guard FirebaseConfiguration.isConfigured else { return }
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                await self?.handleAuthStateChange(user: user)
            }
        }
    }

    private func handleAuthStateChange(user: User?) async {
        if let user, !hasValidatedInitialSession {
            hasValidatedInitialSession = true
            do {
                _ = try await user.getIDToken(forcingRefresh: true)
                self.user = user
                isAuthenticated = true
            } catch {
                if isInvalidCredentialError(error) {
                    signOutForExpiredSession()
                } else {
                    self.user = user
                    isAuthenticated = true
                }
            }
        } else {
            self.user = user
            isAuthenticated = user != nil
        }
        hasResolvedInitialAuthState = true
    }

    private func handleAuthFailure(_ error: Error, context: AuthErrorContext) {
        if isInvalidCredentialError(error) {
            switch context {
            case .emailPassword:
                Self.clearPersistedSignInSessions()
                user = nil
                isAuthenticated = false
                errorMessage = "Incorrect email or password."
            default:
                signOutForExpiredSession()
            }
            return
        }
        errorMessage = friendlyAuthError(error, context: context)
    }

    private func signOutForExpiredSession(message: String = "Session expired. Please sign in again.") {
        Self.clearPersistedSignInSessions()
        user = nil
        isAuthenticated = false
        clearedStaleSession = true
        errorMessage = message
    }

    private func isGoogleSignInCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == GIDSignInError.errorDomain
            && nsError.code == GIDSignInError.canceled.rawValue
    }

    private func isInvalidCredentialError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .invalidCredential, .userTokenExpired, .invalidUserToken:
                return true
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("malformed")
            || message.contains("expired")
            || message.contains("invalid-credential")
            || message.contains("invalid credential")
    }

    private func friendlyAuthError(_ error: Error, context: AuthErrorContext) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .emailAlreadyInUse:
                return "An account already exists for this email."
            case .invalidEmail:
                return "Enter a valid email address."
            case .weakPassword:
                return "Password must be at least 6 characters."
            case .wrongPassword:
                return "Incorrect password. Try again."
            case .userNotFound:
                switch context {
                case .passwordReset:
                    return "No account found for this email."
                default:
                    return "No account found for this email."
                }
            case .invalidCredential:
                switch context {
                case .emailPassword:
                    return "Incorrect email or password."
                case .oauth:
                    return "Sign-in failed. Please try again."
                case .passwordReset:
                    return "No account found for this email."
                case .sessionRecovery:
                    return "Session expired. Please sign in again."
                case .general:
                    return "Session expired. Please sign in again."
                }
            case .userTokenExpired, .invalidUserToken:
                return "Session expired. Please sign in again."
            case .networkError:
                return "Network error. Check your connection and try again."
            case .tooManyRequests:
                return "Too many attempts. Wait a moment and try again."
            case .operationNotAllowed:
                return "This sign-in method is not enabled for this app."
            case .credentialAlreadyInUse:
                return "This account is already linked to another sign-in method."
            case .requiresRecentLogin:
                return "For security, please sign in again to continue."
            default:
                break
            }
        }
        return "Something went wrong. Please try again."
    }

    private static func presentationViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first(where: \.isKeyWindow)
        return window?.rootViewController
    }

    static func previewAuthenticated() -> AuthenticationManager {
        let manager = AuthenticationManager()
        manager.isAuthenticated = true
        return manager
    }
}
