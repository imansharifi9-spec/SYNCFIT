import Foundation
import FirebaseFunctions

/// Maps Firebase Functions errors from `deleteUserAccount` to user-facing copy.
enum DeleteAccountErrorMapper {
    static let activeClientSubscriptionsMessage =
        "You still have active coach client subscriptions. End them so you have zero active client subscriptions, then try deleting your account again."

    static let genericFailureMessage =
        "We couldn't delete your account. Please try again."

    static func displayMessage(for error: Error) -> String {
        let nsError = error as NSError

        if isActiveClientSubscriptionBlock(nsError) {
            return activeClientSubscriptionsMessage
        }

        if nsError.domain == FunctionsErrorDomain {
            let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
                ?? nsError.localizedDescription
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            return genericFailureMessage
        }

        let trimmed = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? genericFailureMessage : trimmed
    }

    /// Backend uses `failed-precondition` when active coach client subscriptions block deletion.
    static func isActiveClientSubscriptionBlock(_ error: NSError) -> Bool {
        let message = (
            (error.userInfo[NSLocalizedDescriptionKey] as? String)
                ?? error.localizedDescription
        ).lowercased()

        let mentionsBlockingSubscriptions =
            message.contains("subscription")
            || message.contains("active client")

        if error.domain == FunctionsErrorDomain,
           FunctionsErrorCode(rawValue: error.code) == .failedPrecondition {
            return true
        }

        return mentionsBlockingSubscriptions && message.contains("delete")
    }
}
