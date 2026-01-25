//
//  StoreManager.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 25.01.2026.
//

import Combine
import StoreKit
import SwiftUI

enum TipProduct: String, CaseIterable {
    case small = "com.stepanok.simcleaner.tip.small"
    case medium = "com.stepanok.simcleaner.tip.medium"
    case large = "com.stepanok.simcleaner.tip.large"

    var emoji: String {
        switch self {
        case .small: return "☕️"
        case .medium: return "🍕"
        case .large: return "🎉"
        }
    }

    var title: String {
        switch self {
        case .small: return "Coffee"
        case .medium: return "Pizza"
        case .large: return "Party"
        }
    }
}

@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchaseState: PurchaseState = .ready
    @Published var showThankYou: Bool = false

    enum PurchaseState: Equatable {
        case ready
        case purchasing
        case purchased
        case failed(String)
    }

    private var updateListenerTask: Task<Void, Error>?

    init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    func loadProducts() async {
        do {
            let productIds = TipProduct.allCases.map(\.rawValue)
            let storeProducts = try await Product.products(for: productIds)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            print("Failed to load products: \(error)")
        }
    }

    func purchase(_ product: Product) async {
        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                purchaseState = .purchased
                showThankYou = true

            case .userCancelled:
                purchaseState = .ready

            case .pending:
                purchaseState = .ready

            @unknown default:
                purchaseState = .ready
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.purchaseState = .ready
            }
        }
    }

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                do {
                    let transaction = try self?.checkVerified(result)
                    await transaction?.finish()
                } catch {
                    print("Transaction failed verification")
                }
            }
        }
    }

    func resetState() {
        purchaseState = .ready
        showThankYou = false
    }
}

enum StoreError: Error {
    case failedVerification
}
