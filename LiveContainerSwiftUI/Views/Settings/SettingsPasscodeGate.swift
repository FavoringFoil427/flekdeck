//
//  SettingsPasscodeGate.swift
//  LiveContainerSwiftUI
//

import SwiftUI
import CryptoKit

/// A 4-digit gate shown before developer mode is unlocked.
///
/// A soft gate, not real security: the check runs on the device, so a determined
/// person with the binary can get past it. What it does buy is that the code is
/// never written down here — only a salted SHA-256 of it is, so the digits do not
/// appear in the source or the shipped binary and cannot be grepped or `strings`-ed
/// out. It deters a shoulder-surfer or a borrowed phone, nothing more.
struct SettingsPasscodeGate: View {
    let onUnlock: () -> Void
    var onCancel: (() -> Void)? = nil

    @State private var entered = ""
    @State private var shake: CGFloat = 0

    private let slots = 4

    // Salt + hex digest of the accepted code. The value itself lives nowhere in
    // the build; only this fingerprint of it does.
    private static let salt = "flek.core.identity.v3"
    private static let digest = "1228f5676cc466eeff6b3405fcd1d8012a9169215f9bd75b4a47f56938328633"

    private static func accepts(_ code: String) -> Bool {
        let hashed = SHA256.hash(data: Data((salt + code).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // Constant-ish compare; length is fixed so this is just tidiness, the
        // real point is that `digest` reveals nothing.
        return hashed == digest
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onCancel {
                HStack {
                    Spacer()
                    Button("lc.common.cancel".loc) { onCancel() }
                        .padding()
                }
            }

            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            Text("lc.settings.passcode.prompt".loc)
                .font(.headline)
                .padding(.bottom, 26)

            HStack(spacing: 22) {
                ForEach(0..<slots, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                        .background(Circle().fill(i < entered.count ? Color.primary : Color.clear))
                        .frame(width: 15, height: 15)
                }
            }
            .modifier(ShakeEffect(travel: shake))

            Spacer()

            keypad
                .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(row, id: \.self) { digit in
                        digitKey("\(digit)")
                    }
                }
            }
            HStack(spacing: 26) {
                Color.clear.frame(width: 74, height: 74)
                digitKey("0")
                Button {
                    if !entered.isEmpty { entered.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: 74, height: 74)
                        .contentShape(Circle())
                }
                .foregroundStyle(.primary)
                .disabled(entered.isEmpty)
                .opacity(entered.isEmpty ? 0.35 : 1)
            }
        }
    }

    private func digitKey(_ digit: String) -> some View {
        Button {
            append(digit)
        } label: {
            Text(digit)
                .font(.system(size: 30, weight: .regular))
                .frame(width: 74, height: 74)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .foregroundStyle(.primary)
    }

    private func append(_ digit: String) {
        guard entered.count < slots else { return }
        entered.append(digit)
        guard entered.count == slots else { return }

        if Self.accepts(entered) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onUnlock()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.35)) {
                shake += 1
            }
            // Clear after the shake so the wrong dots are visible for a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                entered = ""
            }
        }
    }
}

/// Slides the dot row left-right through one cycle each time `travel` steps by 1.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(travel * .pi * 2), y: 0))
    }
}
