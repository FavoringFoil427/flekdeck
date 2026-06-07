//
//  FlekSearchView.swift
//  LiveContainerSwiftUI
//
//  Springboard search overlay. Opened from the bottom search pill. Searches
//  installed apps; per-source (Installer) results are added once the Installer
//  source cache is reworked.
//

import SwiftUI

struct FlekSearchView: View {
    @Binding var isPresented: Bool
    let apps: [LCAppModel]
    let darkModeIcon: Bool
    var onSelect: (LCAppModel) -> Void

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var results: [LCAppModel] {
        guard !query.isEmpty else { return [] }
        return apps.filter { app in
            (app.appInfo.displayName()?.localizedCaseInsensitiveContains(query) ?? false) ||
            (app.appInfo.bundleIdentifier()?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ZStack {
            FlekWallpaperView().blur(radius: 35).overlay(Color.black.opacity(0.15))
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 14) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if query.isEmpty {
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    Text("lc.flek.noResults".loc)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("lc.flek.installed".loc)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                            ForEach(results, id: \.self) { app in
                                Button {
                                    onSelect(app)
                                    close()
                                } label: {
                                    FlekSearchRow(app: app, darkModeIcon: darkModeIcon)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("lc.flek.searchApps".loc, text: $query)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                // Clears the input, closes search and returns to the home screen.
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func close() {
        query = ""
        isPresented = false
    }
}

private struct FlekSearchRow: View {
    let app: LCAppModel
    let darkModeIcon: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon))
                .resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appInfo.displayName() ?? "?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 68)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }
}
