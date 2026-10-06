// Purchase.swift: the one in-app purchase of the Mac App Store build, with
// StoreKit 2. Compiled in only with -D STORE; the GPL build gets the stub at
// the bottom, which always reports purchased.
//
// Only verified transactions count (VerificationResult.verified). A revoked
// purchase (refund) stops counting at the next refresh or update.
import Foundation

#if STORE
import StoreKit

enum PurchaseError: Error, LocalizedError {
    case productUnavailable
    case unverified(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable: return "The App Store did not return the product."
        case .unverified(let why): return "The App Store transaction could not be verified: \(why)"
        }
    }
}

@available(macOS 13.0, *)
@MainActor
final class Purchases {
    static let productID = "io.github.shipsfromrio.ipsio.lifetime"

    /// Called on the main actor whenever the purchased state changes (an
    /// update from another device, Ask to Buy approved, a refund, a buy, a restore).
    var onChange: (Bool) -> Void = { _ in }
    private(set) var purchased = false
    /// The last buy() ended pending (Ask to Buy, SCA): the updates listener
    /// unlocks the app when the App Store confirms.
    private(set) var lastBuyPending = false
    private(set) var product: Product?
    private var updates: Task<Void, Never>?

    init() {
        // Started at once: a transaction that completes while the app is not
        // looking (Ask to Buy, another Mac) arrives here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                guard let self else { return }
                _ = await self.refresh()
            }
        }
    }

    deinit { updates?.cancel() }

    /// The localized price, for the menu item ("US$ 19.99"); nil if the App
    /// Store did not answer.
    func displayPrice() async -> String? {
        await loadProduct()?.displayPrice
    }

    /// Reads the current entitlements. True only for a verified, unrevoked
    /// transaction of the lifetime product.
    @discardableResult
    func refresh() async -> Bool {
        var has = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            if t.productID == Self.productID && t.revocationDate == nil { has = true }
        }
        set(has)
        return has
    }

    /// .success(true): bought (or already owned). .success(false): cancelled
    /// or pending (see lastBuyPending). .failure: no product, unverified, or
    /// the App Store failed.
    func buy() async -> Result<Bool, Error> {
        lastBuyPending = false
        guard let p = await loadProduct() else { return .failure(PurchaseError.productUnavailable) }
        do {
            switch try await p.purchase() {
            case .success(let result):
                switch result {
                case .verified(let t):
                    await t.finish()
                    set(t.revocationDate == nil)
                    return .success(purchased)
                case .unverified(_, let why):
                    return .failure(PurchaseError.unverified(String(describing: why)))
                }
            case .pending:
                lastBuyPending = true
                return .success(false)
            case .userCancelled:
                return .success(false)
            @unknown default:
                return .success(false)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Restore: AppStore.sync() asks the App Store for this account's
    /// transactions (it may ask the user to sign in), then reads them.
    func restore() async -> Bool {
        try? await AppStore.sync()
        return await refresh()
    }

    private func loadProduct() async -> Product? {
        if let p = product { return p }
        product = (try? await Product.products(for: [Self.productID]))?.first
        return product
    }

    private func set(_ has: Bool) {
        let changed = has != purchased
        purchased = has
        if changed { onChange(has) }
    }
}

#else

/// The GPL build: no store, always purchased. Same API, so the app code does
/// not need #if around every call.
@available(macOS 13.0, *)
@MainActor
final class Purchases {
    static let productID = "io.github.shipsfromrio.ipsio.lifetime"
    var onChange: (Bool) -> Void = { _ in }
    let purchased = true
    let lastBuyPending = false
    init() {}
    func displayPrice() async -> String? { nil }
    @discardableResult
    func refresh() async -> Bool { true }
    func buy() async -> Result<Bool, Error> { .success(true) }
    func restore() async -> Bool { true }
}

#endif
