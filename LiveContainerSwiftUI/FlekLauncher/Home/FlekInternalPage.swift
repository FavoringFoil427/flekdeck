//
//  FlekInternalPage.swift
//  LiveContainerSwiftUI
//
//  Hosts a built-in FlekLauncher page (Settings / Installer) as a full-screen
//  cover. Multitasking is intentionally not wired up yet, so a single glass
//  "back to home" chevron at the bottom returns to the springboard. This is a
//  placeholder for the future multitasking switcher bar.
//

import SwiftUI

struct FlekInternalPage<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlay(alignment: .bottom) {
                FlekGlassCircleButton(systemImage: "chevron.down", size: 44, iconScale: 0.42) {
                    isPresented = false
                }
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
    }
}
