//
//  FlekSearchView.swift
//  LiveContainerSwiftUI
//
//  Springboard search. Presented as an overlay over the (dimmed, blurred) home
//  screen: results fill from the top and the search field sits in a bottom bar
//  just above the keyboard, matching the FlekSign design. Searches installed
//  apps; per-source (Installer) results are added with the Installer rework.
//

import SwiftUI

struct FlekSearchView: View {
    @Binding var isPresented: Bool
    let apps: [LCAppModel]
    let darkModeIcon: Bool
    var onSelect: (LCAppModel) -> Void
    var onInstallStoreApp: (FSAppModel) -> Void = { _ in }

    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @StateObject private var storeVM = FlekstoreAppsListViewModel()

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)

    private var results: [LCAppModel] {
        guard !query.isEmpty else { return [] }
        return apps.filter { app in
            (app.appInfo.displayName()?.localizedCaseInsensitiveContains(query) ?? false) ||
            (app.appInfo.bundleIdentifier()?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                resultsArea
                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            fieldFocused = true
            storeVM.repository = .flekstore
            Task { await storeVM.refreshSubscriptionStatus() }
        }
        .onChange(of: query) { q in
            storeVM.searchQuery = q
            storeVM.debounceSearch(q)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if query.isEmpty {
            Spacer()
        } else if results.isEmpty && storeVM.apps.isEmpty && !storeVM.isLoading {
            Spacer()
            Text("lc.flek.noResults".loc)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !results.isEmpty {
                        section(title: "lc.flek.installed".loc) {
                            ForEach(results, id: \.self) { app in
                                Button {
                                    onSelect(app)
                                    close()
                                } label: {
                                    FlekSearchRow(app: app, darkModeIcon: darkModeIcon)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !storeVM.apps.isEmpty {
                        section(title: "FlekSt0re") {
                            ForEach(storeVM.apps) { app in
                                Button {
                                    FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
                                    onInstallStoreApp(app)
                                    close()
                                } label: {
                                    FlekStoreSearchRow(app: app)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if storeVM.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 80)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            content()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Search field pill
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(.black.opacity(0.6))
                TextField("lc.flek.search".loc, text: $query)
                    .font(.system(size: 18))
                    .foregroundStyle(.black)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().fill(Color.white.opacity(0.45)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .compositingGroup()

            // Clear + close button (returns to the home screen)
            Button {
                close()
            } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.white.opacity(0.45)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    Image(systemName: "xmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func close() {
        query = ""
        fieldFocused = false
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
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.black.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .frame(height: 68)
        .flekGlassCard(cornerRadius: 16)
    }
}

private struct FlekStoreSearchRow: View {
    let app: FSAppModel

    var body: some View {
        HStack(spacing: 12) {
            FlekRemoteIcon(url: app.app_icon, size: 48, corner: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app_name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(app.app_version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.55))
                    .lineLimit(1)
                if !app.app_short_description.isEmpty {
                    Text(app.app_short_description)
                        .font(.system(size: 12))
                        .foregroundStyle(.black.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color(red: 0/255, green: 117/255, blue: 255/255))
        }
        .padding(.horizontal, 12)
        .frame(height: 68)
        .flekGlassCard(cornerRadius: 16)
    }
}
