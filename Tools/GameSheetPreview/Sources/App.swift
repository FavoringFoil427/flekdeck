//
//  App.swift — GameSheetPreview
//
//  Standalone harness for previewing FlekGameWarningView (the "Recommended for
//  games" sheet) on multiple iOS runtimes without building all of LiveContainer.
//
//  Deep links drive it so screenshots can be scripted:
//     gspreview://variant/<index>   — pick a background treatment and show the sheet
//     gspreview://close             — dismiss
//

import SwiftUI

// MARK: - Background treatments under test

enum SheetSkin: Int, CaseIterable, Identifiable {
    case shipping = 0      // what LiveContainer ships: clear on 26+, material below
    case legacyClear       // the old behaviour: clear on everything 16.4+
    case systemDefault     // no presentationBackground override at all
    case flekGlass         // matches FlekGlassBackground (ultraThin + white tint + hairline)
    case regularMaterial   // .regularMaterial on every version
    case opaque            // solid systemBackground
    case ios15             // reproduces the iOS 15 code path on any runtime

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shipping:        return "Shipping (glass on 26, material below)"
        case .legacyClear:     return "Legacy (.clear on 16.4+)"
        case .systemDefault:   return "System default sheet"
        case .flekGlass:       return "Flek glass (ultraThin + tint)"
        case .regularMaterial: return ".regularMaterial everywhere"
        case .opaque:          return "Opaque systemBackground"
        case .ios15:           return "iOS 15 path (no detents at all)"
        }
    }

    var shortTitle: String {
        switch self {
        case .shipping:        return "Shipping"
        case .legacyClear:     return "Legacy clear"
        case .systemDefault:   return "System"
        case .flekGlass:       return "Flek glass"
        case .regularMaterial: return "Regular mat."
        case .opaque:          return "Opaque"
        case .ios15:           return "iOS 15 path"
        }
    }
}

// MARK: - Entry point

@main
struct GameSheetPreviewApp: App {
    @State private var skin: SheetSkin = .shipping
    @State private var showSheet = false

    var body: some Scene {
        WindowGroup {
            HarnessView(skin: $skin, showSheet: $showSheet)
                .onOpenURL { url in
                    guard url.scheme == "gspreview" else { return }
                    if url.host == "close" {
                        showSheet = false
                        return
                    }
                    if url.host == "variant",
                       let raw = Int(url.lastPathComponent),
                       let s = SheetSkin(rawValue: raw) {
                        showSheet = false
                        skin = s
                        // Let the previous sheet finish tearing down before re-presenting.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showSheet = true
                        }
                    }
                }
        }
    }
}

// MARK: - Harness chrome

struct HarnessView: View {
    @Binding var skin: SheetSkin
    @Binding var showSheet: Bool

    var body: some View {
        ZStack(alignment: .top) {
            SpringboardBackdrop()

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("iOS \(UIDevice.current.systemVersion)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(skin.shortTitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
                .padding(.top, 58)

                Spacer()

                Picker("Skin", selection: $skin) {
                    ForEach(SheetSkin.allCases) { s in
                        Text(s.shortTitle).tag(s)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
                .padding(.horizontal, 20)

                Button {
                    showSheet = true
                } label: {
                    Text("Show sheet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal, 20).padding(.bottom, 34)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSheet) {
            FlekGameWarningView(appName: "Genshin Impact", skin: skin) { _, _ in }
        }
    }
}

// MARK: - Fake springboard so sheet transparency is actually visible

struct SpringboardBackdrop: View {
    private let tiles: [(String, String)] = [
        ("gamecontroller.fill", "Genshin"), ("bolt.fill", "Brawl"), ("crown.fill", "Clash"),
        ("cube.fill", "Roblox"), ("flame.fill", "PUBG"), ("star.fill", "Sky"),
        ("leaf.fill", "Stardew"), ("moon.fill", "Alto"), ("car.fill", "Asphalt")
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.11, green: 0.16, blue: 0.42),
                                    Color(red: 0.42, green: 0.16, blue: 0.46),
                                    Color(red: 0.86, green: 0.36, blue: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 8) {
                Spacer().frame(height: 90)
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { col in
                            let t = tiles[row * 3 + col]
                            VStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.55)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(width: 74, height: 74)
                                    .overlay(Image(systemName: t.0)
                                        .font(.system(size: 32, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.35)))
                                Text(t.1).font(.system(size: 14)).foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.white.opacity(0.22))))
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .ignoresSafeArea()
        .preferredColorScheme(nil)
    }
}
