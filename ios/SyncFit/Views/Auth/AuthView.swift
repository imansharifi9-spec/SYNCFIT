import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty && password.count >= 6 && !authManager.isLoading
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var firebaseSetupMessage: String {
        if FirebaseConfiguration.isAvailable {
            return "Firebase failed to start in this build. Delete the app from your phone, clean the build folder in Xcode, then run again."
        }
        return "Add GoogleService-Info.plist to the SyncFit target in Xcode, then delete the app from your phone and reinstall."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        Text("SyncFit")
                            .font(.system(size: 36, weight: .bold, design: .rounded))

                        Text("Everything. In Sync.")
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(SyncFitTheme.accent)
                    }
                    .padding(.top, 32)

                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .background(SyncFitTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        SecureField("Password", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                            .padding()
                            .background(SyncFitTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if !isSignUp {
                            HStack {
                                Spacer()
                                Button("Forgot password?") {
                                    Task {
                                        await authManager.sendPasswordReset(email: trimmedEmail)
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(SyncFitTheme.accent)
                                .disabled(authManager.isLoading || !FirebaseConfiguration.isConfigured)
                            }
                        }

                        Button {
                            Task {
                                if isSignUp {
                                    await authManager.signUp(email: trimmedEmail, password: password)
                                } else {
                                    await authManager.signIn(email: trimmedEmail, password: password)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if authManager.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(isSignUp ? "Create Account" : "Sign In")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSubmit)

                        Button(isSignUp ? "Already have an account? Sign in" : "New here? Create an account") {
                            isSignUp.toggle()
                            authManager.errorMessage = nil
                            authManager.infoMessage = nil
                        }
                        .font(.subheadline)
                        .foregroundStyle(SyncFitTheme.accent)

                        if let infoMessage = authManager.infoMessage {
                            Text(infoMessage)
                                .font(.caption)
                                .foregroundStyle(SyncFitTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let errorMessage = authManager.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !FirebaseConfiguration.isConfigured {
                            Text(firebaseSetupMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(height: 1)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(height: 1)
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await authManager.signInWithGoogle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if authManager.isLoading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "g.circle.fill")
                                        .font(.title3)
                                }
                                Text("Continue with Google")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GoogleSignInButtonStyle())
                        .disabled(authManager.isLoading || !FirebaseConfiguration.isConfigured)

                        SignInWithAppleButton(
                            style: colorScheme == .dark ? .white : .black,
                            isEnabled: !authManager.isLoading && FirebaseConfiguration.isConfigured
                        ) { result in
                            switch result {
                            case .success(let payload):
                                Task {
                                    await authManager.signInWithApple(
                                        authorization: payload.0,
                                        nonce: payload.1
                                    )
                                }
                            case .failure(let error):
                                if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                    authManager.errorMessage = "Apple sign-in failed. Try again."
                                }
                            }
                        }
                        .frame(height: 50)
                    }

                    SyncFitCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Free forever", systemImage: "checkmark.circle.fill")
                            Label("Workout & nutrition tracking", systemImage: "checkmark.circle.fill")
                            Label("Cloud sync with your account", systemImage: "checkmark.circle.fill")
                        }
                        .foregroundStyle(SyncFitTheme.accent)
                        .font(.subheadline)
                    }
                }
                .padding()
            }
            .background(SyncFitTheme.background)
            .navigationBarHidden(true)
            .onChange(of: email) { _, _ in
                authManager.infoMessage = nil
            }
            .onChange(of: authManager.clearedStaleSession) { _, cleared in
                guard cleared else { return }
                password = ""
                authManager.acknowledgeSessionClear()
            }
        }
    }
}

private struct GoogleSignInButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.primary)
            .padding()
            .background(SyncFitTheme.card.opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    AuthView()
        .environmentObject(AuthenticationManager())
}
