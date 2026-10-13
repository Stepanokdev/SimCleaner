//
//  SupportAuthorView.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 25.01.2026.
//

import SwiftUI
import StoreKit

struct SupportAuthorView: View {
    @StateObject private var storeManager = StoreManager()
    @Environment(\.dismiss) private var dismiss

    private let youtubeURL = URL(string: "https://www.youtube.com/@stepanokdev")!
    private let tealGradient = LinearGradient(
        colors: [
            Color(red: 0.0, green: 0.3, blue: 0.35).opacity(0.0),
            Color(red: 0.0, green: 0.3, blue: 0.35).opacity(0.95),
            Color(red: 0.0, green: 0.25, blue: 0.3)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack {
            backgroundImage
            contentOverlay
        }
        .frame(width: 520, height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .alert("Thank you!", isPresented: $storeManager.showThankYou) {
            Button("You're welcome!") {
                storeManager.resetState()
            }
        } message: {
            Text("Your support means a lot to me! Thank you for helping me continue creating useful tools for the iOS community.")
        }
    }

    private var backgroundImage: some View {
        ZStack {
            Color.black
            Image("stepanok")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 520, height: 520, alignment: .top)
        }
    }

    private var contentOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                messageText
                youtubeButton
                tipButtons
            }
            .padding(24)
            .padding(.bottom, 8)
        }
        .background(tealGradient)
    }

    private var messageText: some View {
        Text("This app is free because I love creating useful utilities for the iOS developer community. If you'd like to support my work, it's completely optional, but you could subscribe to my YouTube channel (only if you find the content interesting!) or buy me a coffee.")
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
    }

    private var youtubeButton: some View {
        Button {
            NSWorkspace.shared.open(youtubeURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 16))
                Text("Subscribe on YouTube")
                    .fontWeight(.medium)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.red.opacity(0.9), Color.red],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var tipButtons: some View {
        HStack(spacing: 12) {
            ForEach(storeManager.products, id: \.id) { product in
                tipButton(for: product)
            }
        }
    }

    @ViewBuilder
    private func tipButton(for product: Product) -> some View {
        let tipType = TipProduct(rawValue: product.id)

        Button {
            Task {
                await storeManager.purchase(product)
            }
        } label: {
            VStack(spacing: 6) {
                Text(tipType?.emoji ?? "☕️")
                    .font(.system(size: 24))
                Text(tipType?.title ?? "Tip")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text(product.displayPrice)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(storeManager.purchaseState == .purchasing)
        .opacity(storeManager.purchaseState == .purchasing ? 0.6 : 1.0)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

#Preview {
    SupportAuthorView()
}
