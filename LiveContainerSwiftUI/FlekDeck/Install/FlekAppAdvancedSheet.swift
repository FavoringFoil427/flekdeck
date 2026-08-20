//
//  FlekAppAdvancedSheet.swift
//  LiveContainerSwiftUI
//
//  The gear on an app's page: icon, springboard name and bundle ID, chosen
//  before the app is installed and applied to the bundle on its way in.
//
//  All three fields are "leave blank to keep the app's own". None of them can be
//  pre-filled honestly — the IPA's real name, icon and bundle ID only exist once
//  the download has been unpacked — so pre-filling from the catalog listing
//  would quietly rename every app to its store title.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekAppAdvancedSheet: View {
    let app: FSAppModel
    @Binding var overrides: FlekInstallOverrides

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var bundleID: String = ""
    @State private var iconImage: UIImage?
    @State private var choosingIcon = false
    @State private var iconError = false

    private static let hPadding: CGFloat = 20

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    fields
                    resetButton
                }
                .padding(.horizontal, Self.hPadding)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("lc.flek.advanced.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            name = overrides.displayName ?? ""
            bundleID = overrides.bundleID ?? ""
            loadIconPreview()
        }
        .onChange(of: name) { overrides.displayName = normalized($0) }
        .onChange(of: bundleID) { overrides.bundleID = normalized($0) }
        .betterFileImporter(isPresented: $choosingIcon,
                            types: [.png, .jpeg],
                            multiple: false,
                            callback: { urls in
            guard let picked = urls.first else { return }
            chooseIcon(picked)
        }, onDismiss: { choosingIcon = false })
        .alert("lc.flek.advanced.iconFailedTitle".loc, isPresented: $iconError) {
            Button("lc.common.ok".loc) {}
        } message: {
            Text("lc.flek.advanced.iconFailedMsg".loc)
        }
    }

    // MARK: Sections

    private var intro: some View {
        Text("lc.flek.advanced.intro".loc)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            iconRow
            Divider().padding(.leading, 16)
            textRow(title: "lc.flek.advanced.customName".loc,
                    placeholder: app.app_name,
                    text: $name,
                    autocapitalization: .words)
            Divider().padding(.leading, 16)
            textRow(title: "lc.flek.advanced.bundleId".loc,
                    placeholder: "lc.flek.advanced.bundleIdPlaceholder".loc,
                    text: $bundleID,
                    autocapitalization: .never)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private var iconRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lc.flek.advanced.appIcon".loc)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if let iconImage {
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("lc.flek.advanced.iconPlaceholder".loc)
                        .font(.system(size: 17))
                        .foregroundStyle(Color(.tertiaryLabel))
                }

                Spacer(minLength: 8)

                if iconImage != nil {
                    Button {
                        clearIcon()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("lc.common.remove".loc)
                }

                Button {
                    choosingIcon = true
                } label: {
                    Text("lc.flek.advanced.browse".loc)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Capsule().fill(Color(.tertiarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func textRow(title: String, placeholder: String,
                         text: Binding<String>,
                         autocapitalization: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(autocapitalization)

                // Clears the field in one tap, back to "keep whatever the app
                // already uses" — which is what the placeholder then spells out.
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("lc.common.remove".loc)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: text.wrappedValue.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Anything that differs from what the app would install as. The name is
    /// seeded with the app's own, so a non-empty `overrides` is not by itself
    /// a customisation — clearing the name is.
    private var hasCustomisation: Bool {
        overrides.iconFileURL != nil
            || overrides.bundleID != nil
            || overrides.displayName != app.app_name
    }

    @ViewBuilder
    private var resetButton: some View {
        if hasCustomisation {
            Button {
                reset()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                    Text("lc.flek.advanced.reset".loc)
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func chooseIcon(_ picked: URL) {
        // Copy it somewhere we own straight away: the picker's URL is
        // security-scoped and won't still be readable when the install runs.
        guard let staged = FlekInstallOverrides.stageIcon(from: picked) else {
            iconError = true
            return
        }
        overrides.cleanUpStagedIcon()
        overrides.iconFileURL = staged
        loadIconPreview()
    }

    private func clearIcon() {
        overrides.cleanUpStagedIcon()
        overrides.iconFileURL = nil
        iconImage = nil
    }

    private func loadIconPreview() {
        guard let url = overrides.iconFileURL,
              let data = try? Data(contentsOf: url) else {
            iconImage = nil
            return
        }
        iconImage = UIImage(data: data)
    }

    /// Back to what the app would install as: its own name in the field, no
    /// custom icon, and the bundle ID left to the IPA.
    private func reset() {
        overrides.cleanUpStagedIcon()
        overrides = FlekInstallOverrides(displayName: app.app_name)
        name = app.app_name
        bundleID = ""
        iconImage = nil
    }
}
