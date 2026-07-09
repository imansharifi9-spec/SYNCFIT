import Foundation
import FirebaseCore
import GoogleSignIn

enum FirebaseConfiguration {
    static var plistURL: URL? {
        if let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") {
            return url
        }
        return Bundle.main.urls(forResourcesWithExtension: "plist", subdirectory: nil)?
            .first { $0.lastPathComponent.hasPrefix("GoogleService-Info") }
    }

    static var isAvailable: Bool {
        plistURL != nil
    }

    static var isConfigured: Bool {
        FirebaseApp.app() != nil
    }

    static func configureIfNeeded() {
        guard !isConfigured else {
            configureGoogleSignInIfNeeded()
            return
        }
        guard let plistURL else { return }
        guard let options = FirebaseOptions(contentsOfFile: plistURL.path) else { return }
        FirebaseApp.configure(options: options)
        configureGoogleSignInIfNeeded()
    }

    static func configureGoogleSignInIfNeeded() {
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        if let serverClientID = googleWebClientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                clientID: clientID,
                serverClientID: serverClientID
            )
        } else {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    /// Web OAuth client ID from Firebase Console → Authentication → Google → Web client ID.
    /// Add as `WEB_CLIENT_ID` in GoogleService-Info.plist if Google Sign-In returns invalid-credential.
    private static var googleWebClientID: String? {
        guard let plistURL,
              let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return nil
        }
        let keys = ["WEB_CLIENT_ID", "WEB_CLIENTID", "GOOGLE_WEB_CLIENT_ID"]
        for key in keys {
            if let value = plist[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func handleIncomingURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}
