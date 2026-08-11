//
//  FlekGameWarningView.swift — verbatim copy of the shipping view, with a
//  `skin` knob added so alternative sheet backgrounds can be compared.
//  Everything above the `.apply { }` block is byte-for-byte the production code.
//

import SwiftUI

private struct FlekGameSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}

/// Production copy uses `"key".loc`; here the English values from
/// Resources/Localizable.xcstrings are inlined so the layout matches exactly.
extension String {
    var loc: String {
        switch self {
        case "lc.flek.game.title":       return "Recommended for games"
        case "lc.flek.game.desc":        return "Games usually run better in Single Mode. Single Mode gives the game more resources, but you'll need to close FlekLauncher to exit it."
        case "lc.flek.game.remember":    return "Remember my choice for this app"
        case "lc.flek.game.runSingle":   return "Run Single"
        case "lc.flek.game.runParallel": return "Run Parallel Anyway"
        default: return self
        }
    }
}

struct FlekGameWarningView: View {
    let appName: String
    var skin: SheetSkin = .shipping
    var onChoose: (_ parallel: Bool, _ remember: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var remember = true
    @State private var sheetHeight: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.26, green: 0.6, blue: 1.0),
                                                      Color(red: 0/255, green: 117/255, blue: 255/255)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 64, height: 64)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color(white: 0.95))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 51, height: 51)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 22)

            VStack(alignment: .leading, spacing: 12) {
                Text("lc.flek.game.title".loc)
                    .font(.system(size: 20, weight: .semibold))
                Text("lc.flek.game.desc".loc)
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 20)

            Button {
                remember.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: remember ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28))
                        .foregroundStyle(remember ? Color.accentColor : .secondary)
                    Text("lc.flek.game.remember".loc).font(.system(size: 18)).foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.vertical, 18)

            VStack(spacing: 12) {
                Button {
                    onChoose(true, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runParallel".loc, systemImage: "macwindow.on.rectangle")
                        .font(.system(size: 19, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)

                Button {
                    onChoose(false, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runSingle".loc, systemImage: "app.dashed")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 26)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FlekGameSheetHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(FlekGameSheetHeightKey.self) { h in
            if h > 0 { sheetHeight = h }
        }
        // --- harness-only: content-level backdrop for skins that clear the sheet background ---
        .apply { v in
            if skin == .flekGlass {
                v.background(
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Rectangle().fill(Color.white.opacity(0.22))
                    }
                    .clipShape(RoundedCorners(radius: 38, corners: [.topLeft, .topRight]))
                    .overlay(
                        RoundedCorners(radius: 38, corners: [.topLeft, .topRight])
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            } else {
                v
            }
        }
        .apply { v in
            switch skin {
            case .shipping:
                if #available(iOS 26.0, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.clear))
                } else if #available(iOS 16.4, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.regularMaterial))
                } else {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible))
                }
            case .legacyClear:
                if #available(iOS 16.4, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.clear))
                }
                return AnyView(v.presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible))
            case .systemDefault:
                return AnyView(v.presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible))
            case .flekGlass:
                if #available(iOS 16.4, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.clear))
                }
                return AnyView(v.presentationDetents([.height(sheetHeight)]))
            case .regularMaterial:
                if #available(iOS 16.4, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.regularMaterial))
                }
                return AnyView(v.presentationDetents([.height(sheetHeight)]))
            case .opaque:
                if #available(iOS 16.4, *) {
                    return AnyView(v.presentationDetents([.height(sheetHeight)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Color(.systemBackground)))
                }
                return AnyView(v.presentationDetents([.height(sheetHeight)]))
            case .ios15:
                // The production view's final `else { v }` branch: no detents, no
                // drag indicator, no background override. A detent-less sheet on a
                // modern runtime behaves like an iOS 15 page sheet, so this shows
                // the iOS 15 layout without needing an iOS 15 runtime.
                return AnyView(v)
            }
        }
    }
}

/// Top-corner-only rounding (UIBezierPath based, works on every target here).
struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect,
                          byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
