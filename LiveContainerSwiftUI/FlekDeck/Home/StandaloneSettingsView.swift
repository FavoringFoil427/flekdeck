//
//  StandaloneSettingsView.swift
//  LiveContainer
//
//  Standalone wrapper for LCSettingsView that provides its own
//  @State for appDataFolderNames and tweakFolderNames, so it can
//  be presented outside of LCAppListView (e.g. as a multitask window).
//

import SwiftUI

struct StandaloneSettingsView: View {
    @State private var appDataFolderNames: [String] = []
    @State private var tweakFolderNames: [String] = []

    var body: some View {
        LCSettingsView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames)
            .onAppear {
                loadFolderNames()
            }
    }

    private func loadFolderNames() {
        let fm = FileManager.default
        do {
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            appDataFolderNames = dataDirs.filter {
                LCPath.dataPath.appendingPathComponent($0).hasDirectoryPath
            }
        } catch {
            appDataFolderNames = []
        }
        do {
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            tweakFolderNames = tweakDirs.filter {
                LCPath.tweakPath.appendingPathComponent($0).hasDirectoryPath
            }
        } catch {
            tweakFolderNames = []
        }
    }
}
