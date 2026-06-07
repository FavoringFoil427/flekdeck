//
//  FlekGameWarningView.swift
//  LiveContainerSwiftUI
//
//  Shown when launching a game for the first time (no remembered launch mode).
//  Recommends Single Mode; the "remember my choice" toggle is on by default.
//

import SwiftUI

struct FlekGameWarningView: View {
    let appName: String
    var onChoose: (_ parallel: Bool, _ remember: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var remember = true

    var body: some View {
        VStack(spacing: 0) {
            // Header icon
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.26, green: 0.6, blue: 1.0),
                                                  Color(red: 0/255, green: 117/255, blue: 255/255)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(white: 0.95))
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("lc.flek.game.title".loc)
                    .font(.system(size: 17, weight: .semibold))
                Text("lc.flek.game.desc".loc)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 16)

            Button {
                remember.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: remember ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(remember ? Color.accentColor : .secondary)
                    Text("lc.flek.game.remember".loc).font(.system(size: 16)).foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.vertical, 14)

            VStack(spacing: 10) {
                Button {
                    onChoose(true, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runParallel".loc, systemImage: "square.on.square")
                        .font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)

                Button {
                    onChoose(false, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runSingle".loc, systemImage: "1.square.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 24)
        }
        .apply { v in
            if #available(iOS 16.0, *) {
                v.presentationDetents([.height(360)]).presentationDragIndicator(.visible)
            } else {
                v
            }
        }
    }
}
