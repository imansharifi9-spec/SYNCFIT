import Foundation
import StoreKit
import FirebaseAuth
import Combine

/// StoreKit 2 subscription owner for SyncFit+.
/// Start once at app launch via `start()` — `Transaction.updates` must outlive any view.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let plusMonthlyProductID = "com.syncfit.app.plus.monthly"
    static let productIDs: Set<String> = [plusMonthlyProductID]

    private static let pendingWriteDefaultsKey = "subscription.pendingFirestoreWrite"
    /// Initial attempt + 3 retries; delays before retries 1 / 2 / 3.
    private let retryBackoffNanoseconds: [UInt64] = [
        1_000_000_000,
        3_000_000_000,
        8_000_000_000
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    /// "active" | "expired" | "none"
    @Published private(set) var subscriptionStatus = "none"
    @Published private(set) var subscriptionExpiresAt: Date?
    @Published private(set) var lastErrorMessage: String?
    /// True when a subscription status write failed and is waiting to sync for the current uid.
    @Published private(set) var hasPendingFirestoreSync = false

    private weak var firestore: FirestoreDatabaseManager?
    private weak var appState: AppState?

    private var updatesTask: Task<Void, Never>?
    private var didStart = false

    func configure(firestore: FirestoreDatabaseManager, appState: AppState) {
        self.firestore = firestore
        self.appState = appState
        refreshPendingFlag()
    }

    /// Clears in-memory subscription flags on Firebase sign-out so the next account
    /// never inherits the previous user's published state in this process.
    /// Pending UserDefaults writes are kept (uid-scoped) for when that user returns.
    func resetForLogout() {
        applyLocalStatus(status: "none", expiresAt: nil, subscribed: false)
        lastErrorMessage = nil
        refreshPendingFlag()
        print("[Subscription] Reset on logout — isSubscribed set to false")
        if isSubscribed {
            print("❌ Logout reset FAILED — isSubscribed still true after logout.")
        } else {
            print("✅ Logout reset confirmed")
        }
    }

    /// Fresh `Transaction.currentEntitlements` pass after login / session restore.
    /// Pending Firestore sync is flushed first.
    func recheckEntitlementsAfterLogin() async {
        let uid = Auth.auth().currentUser?.uid ?? "nil"
        print("[Subscription] Re-checking entitlements for uid=\(uid) after login")
        await flushPendingFirestoreWriteIfNeeded()
        await refreshEntitlements(reason: "after_login")
        await verifyFirestoreMatchesStoreKit(uid: uid)
    }

    /// Call exactly once at app launch. Starts the lifetime `Transaction.updates` listener
    /// and loads products + current entitlements.
    func start() {
        guard !didStart else {
            print("[Subscription] start() skipped — already running")
            return
        }
        didStart = true
        print("[Subscription] start() — lifetime Transaction.updates listener")
        updatesTask = Task { [weak self] in
            await self?.listenForTransactionUpdates()
        }
        Task { [weak self] in
            await self?.loadProducts()
            // Products only here. Entitlement → isSubscribed is applied after auth
            // (session restore / login) so we never stamp a prior session's UI state
            // before the signed-in uid is known. Pending writes flush on login/recheck.
        }
    }

    // MARK: - Products

    func loadProducts() async {
        print("[Subscription] Product load START ids=\(Self.productIDs.sorted())")
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.id < $1.id }
            if loaded.isEmpty {
                print("[Subscription] Product load OK but empty — check StoreKit Configuration / App Store Connect IDs")
            } else {
                for product in loaded {
                    print(
                        "[Subscription] Product load OK id=\(product.id) " +
                        "display=\(product.displayName) price=\(product.displayPrice)"
                    )
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            print("[Subscription] Product load FAILED: \(error)")
        }
    }

    // MARK: - Purchase / restore

    func purchase() async throws {
        if products.isEmpty {
            print("[Subscription] purchase — products empty, reloading…")
            await loadProducts()
        }
        guard let product = products.first(where: { $0.id == Self.plusMonthlyProductID }) else {
            let message =
                "SyncFit+ product not loaded. In Xcode: Product → Scheme → Edit Scheme → " +
                "Run → Options → StoreKit Configuration → select SyncFit.storekit. " +
                "Then stop the app and run again. (looking for \(Self.plusMonthlyProductID))"
            print("[Subscription] purchase FAILED — \(message)")
            lastErrorMessage = message
            throw SubscriptionError.productUnavailable
        }

        print("[Subscription] purchase START product=\(product.id)")
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            print("[Subscription] purchase OK transactionID=\(transaction.id) product=\(transaction.productID)")
            await transaction.finish()
            await refreshEntitlements(reason: "purchase_success")
        case .userCancelled:
            print("[Subscription] purchase cancelled by user")
        case .pending:
            print("[Subscription] purchase pending (Ask to Buy / deferred)")
        @unknown default:
            print("[Subscription] purchase unknown result")
        }
    }

    func restorePurchases() async {
        print("[Subscription] restorePurchases START (AppStore.sync)")
        do {
            try await AppStore.sync()
            print("[Subscription] restorePurchases AppStore.sync OK")
            await refreshEntitlements(reason: "restore")
        } catch {
            lastErrorMessage = error.localizedDescription
            print("[Subscription] restorePurchases FAILED: \(error)")
        }
    }

    // MARK: - Entitlements

    func refreshEntitlements(reason: String) async {
        let uid = Auth.auth().currentUser?.uid ?? "nil"
        print("[Subscription] Entitlement check START reason=\(reason) uid=\(uid)")

        await flushPendingFirestoreWriteIfNeeded()

        var latestPlus: Transaction?
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                print(
                    "[Subscription] Entitlement found product=\(transaction.productID) " +
                    "id=\(transaction.id) expires=\(String(describing: transaction.expirationDate)) " +
                    "revocation=\(String(describing: transaction.revocationDate))"
                )
                guard Self.productIDs.contains(transaction.productID) else { continue }
                if transaction.revocationDate != nil { continue }
                if let existing = latestPlus {
                    let existingExp = existing.expirationDate ?? .distantPast
                    let newExp = transaction.expirationDate ?? .distantPast
                    if newExp > existingExp {
                        latestPlus = transaction
                    }
                } else {
                    latestPlus = transaction
                }
            } catch {
                print("[Subscription] Entitlement verification FAILED: \(error)")
            }
        }

        let now = Date()
        let status: String
        if let latestPlus {
            let expires = latestPlus.expirationDate
            let stillActive = expires.map { $0 > now } ?? true
            if stillActive {
                status = "active"
                applyLocalStatus(status: status, expiresAt: expires, subscribed: true)
            } else {
                status = "expired"
                applyLocalStatus(status: status, expiresAt: expires, subscribed: false)
            }
        } else {
            status = "none"
            applyLocalStatus(status: status, expiresAt: nil, subscribed: false)
        }

        print("[Subscription] Entitlement check result for uid=\(uid): \(status)")
        await syncSubscriptionToFirestore()
    }

    /// After login write: confirm Firestore `users/{uid}.subscriptionStatus` matches
    /// a fresh StoreKit entitlement scan for this session.
    private func verifyFirestoreMatchesStoreKit(uid: String) async {
        let storeKitStatus = await resolveStoreKitSubscriptionStatus()

        guard let firestore, firestore.isAvailable else {
            print(
                "❌ VERIFICATION FAILED — uid=\(uid) subscriptionStatus=<unavailable> " +
                "does not match this user's actual entitlement. Possible cross-account state leak."
            )
            print("[Subscription] Verification detail: Firestore unavailable; storeKit=\(storeKitStatus)")
            return
        }

        let firestoreStatus: String
        do {
            firestoreStatus = try await firestore.fetchSubscriptionStatus() ?? "none"
            print("[Subscription] Verification read Firestore subscriptionStatus=\(firestoreStatus) for uid=\(uid)")
        } catch {
            print(
                "❌ VERIFICATION FAILED — uid=\(uid) subscriptionStatus=<fetch_failed> " +
                "does not match this user's actual entitlement. Possible cross-account state leak."
            )
            print("[Subscription] Verification detail: Firestore fetch error=\(error); storeKit=\(storeKitStatus)")
            return
        }

        if firestoreStatus == storeKitStatus {
            print(
                "✅ VERIFICATION PASSED — uid=\(uid) subscriptionStatus correctly reflects this " +
                "user's own entitlement (no bleed from previous account)."
            )
        } else {
            print(
                "❌ VERIFICATION FAILED — uid=\(uid) subscriptionStatus=\(firestoreStatus) does not match " +
                "this user's actual entitlement. Possible cross-account state leak."
            )
            print("[Subscription] Verification detail: firestore=\(firestoreStatus) storeKit=\(storeKitStatus)")
        }
    }

    /// Independent StoreKit scan used for post-login self-verification.
    private func resolveStoreKitSubscriptionStatus() async -> String {
        var latestPlus: Transaction?
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                guard Self.productIDs.contains(transaction.productID) else { continue }
                if transaction.revocationDate != nil { continue }
                if let existing = latestPlus {
                    let existingExp = existing.expirationDate ?? .distantPast
                    let newExp = transaction.expirationDate ?? .distantPast
                    if newExp > existingExp {
                        latestPlus = transaction
                    }
                } else {
                    latestPlus = transaction
                }
            } catch {
                continue
            }
        }

        let now = Date()
        if let latestPlus {
            let stillActive = latestPlus.expirationDate.map { $0 > now } ?? true
            return stillActive ? "active" : "expired"
        }
        return "none"
    }

    // MARK: - Transaction.updates (lifetime)

    private func listenForTransactionUpdates() async {
        print("[Subscription] Transaction.updates listener ATTACHED")
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                print(
                    "[Subscription] Transaction.updates event product=\(transaction.productID) " +
                    "id=\(transaction.id) expires=\(String(describing: transaction.expirationDate))"
                )
                await transaction.finish()
                await refreshEntitlements(reason: "transaction_updates")
            } catch {
                print("[Subscription] Transaction.updates verification FAILED: \(error)")
            }
        }
        print("[Subscription] Transaction.updates listener ENDED")
    }

    // MARK: - Firestore sync (retry + pending)

    /// Retries any uid-scoped pending write left from a previous failed sync.
    func flushPendingFirestoreWriteIfNeeded() async {
        guard let uid = Auth.auth().currentUser?.uid,
              let pending = loadPendingWrite(),
              pending.uid == uid else {
            refreshPendingFlag()
            return
        }

        print(
            "[Subscription] Pending write flush START uid=\(uid) " +
            "status=\(pending.status) expiresAt=\(String(describing: pending.expiresAt))"
        )
        await syncSubscriptionToFirestore(
            status: pending.status,
            expiresAt: pending.expiresAt,
            isPendingFlush: true
        )
    }

    private func syncSubscriptionToFirestore() async {
        await syncSubscriptionToFirestore(
            status: subscriptionStatus,
            expiresAt: subscriptionExpiresAt,
            isPendingFlush: false
        )
    }

    private func syncSubscriptionToFirestore(
        status: String,
        expiresAt: Date?,
        isPendingFlush: Bool
    ) async {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            print("[Subscription] Firestore write SKIPPED — not signed in")
            return
        }

        print(
            "[Subscription] Firestore write START users/\(uid) " +
            "subscriptionStatus=\(status) " +
            "subscriptionExpiresAt=\(String(describing: expiresAt)) " +
            "pendingFlush=\(isPendingFlush)"
        )

        var lastError: Error?
        // Attempt 0 = initial; attempts 1...3 = retries after failure.
        for attempt in 0...3 {
            if attempt > 0 {
                print("[Subscription] Firestore write retry attempt \(attempt) after failure")
                let delay = retryBackoffNanoseconds[attempt - 1]
                try? await Task.sleep(nanoseconds: delay)
            }

            do {
                try await performFirestoreSubscriptionWrite(status: status, expiresAt: expiresAt)
                if isPendingFlush {
                    print("[Subscription] Pending write retry succeeded, uid=\(uid)")
                } else {
                    print("[Subscription] Firestore write OK subscriptionStatus=\(status)")
                }
                clearPendingWrite()
                refreshPendingFlag()
                lastErrorMessage = nil
                return
            } catch {
                lastError = error
                print("[Subscription] Firestore write attempt \(attempt) FAILED: \(error)")
            }
        }

        // All attempts failed — keep local entitlement; queue for later; no blocking UI.
        savePendingWrite(uid: uid, status: status, expiresAt: expiresAt)
        refreshPendingFlag()
        handleFirestoreWriteFailure(lastError ?? SubscriptionError.firestoreUnavailable)
    }

    private func performFirestoreSubscriptionWrite(status: String, expiresAt: Date?) async throws {
        guard let firestore, firestore.isAvailable else {
            throw SubscriptionError.firestoreUnavailable
        }
        try await firestore.saveSubscriptionStatus(status: status, expiresAt: expiresAt)
    }

    /// Shared failure path after retries are exhausted.
    /// Does NOT revert `isSubscribed`; no blocking alert — only sets pending + lastErrorMessage.
    private func handleFirestoreWriteFailure(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        print("[Subscription] Firestore write FAILED: \(error)")
        print(
            "[Subscription] Firestore sync exhausted retries — isSubscribed=\(isSubscribed) " +
            "pendingStored=\(hasPendingFirestoreSync)"
        )
    }

    // MARK: - Pending write persistence (UserDefaults)

    private struct PendingSubscriptionFirestoreWrite: Codable {
        let uid: String
        let status: String
        let expiresAt: Date?
    }

    private func savePendingWrite(uid: String, status: String, expiresAt: Date?) {
        let pending = PendingSubscriptionFirestoreWrite(uid: uid, status: status, expiresAt: expiresAt)
        do {
            let data = try JSONEncoder().encode(pending)
            UserDefaults.standard.set(data, forKey: Self.pendingWriteDefaultsKey)
            print("[Subscription] Pending write SAVED uid=\(uid) status=\(status)")
        } catch {
            print("[Subscription] Pending write SAVE FAILED: \(error)")
        }
    }

    private func loadPendingWrite() -> PendingSubscriptionFirestoreWrite? {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingWriteDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingSubscriptionFirestoreWrite.self, from: data)
    }

    private func clearPendingWrite() {
        UserDefaults.standard.removeObject(forKey: Self.pendingWriteDefaultsKey)
        print("[Subscription] Pending write CLEARED")
    }

    private func refreshPendingFlag() {
        if let uid = Auth.auth().currentUser?.uid,
           let pending = loadPendingWrite(),
           pending.uid == uid {
            hasPendingFirestoreSync = true
        } else {
            hasPendingFirestoreSync = false
        }
    }

    // MARK: - Helpers

    private func applyLocalStatus(status: String, expiresAt: Date?, subscribed: Bool) {
        subscriptionStatus = status
        subscriptionExpiresAt = expiresAt
        isSubscribed = subscribed
        if let appState {
            appState.setSyncFitPlusSubscriber(subscribed)
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}

enum SubscriptionError: LocalizedError {
    case productUnavailable
    case firestoreUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "SyncFit+ product didn’t load. Edit Scheme → Run → Options → set StoreKit Configuration to SyncFit.storekit, then rerun."
        case .firestoreUnavailable:
            return "Firestore is unavailable."
        }
    }
}
