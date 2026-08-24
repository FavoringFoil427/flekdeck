//
//  StandaloneSettingsView.swift
//  LiveContainer
//
//  Standalone wrapper for LCSettingsView, so it can be presented outside of
//  LCAppListView (e.g. as a multitask window).
//
//  It used to hold its own @State for appDataFolderNames and tweakFolderNames
//  and hand them down as bindings. Those now live on DataManager's shared model,
//  which LCSettingsView reads from the environment, so all this has left to do is
//  make sure they are populated: a window opened on its own is not guaranteed to
//  come after the launch-time scan that fills them.
//

import SwiftUI

struct StandaloneSettingsView: View {
    var body: some View {
        LCSettingsView()
            .onAppear {
                loadFolderNames()
            }
    }

    private func loadFolderNames() {
        let fm = FileManager.default
        let model = DataManager.shared.model
        do {
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            model.appDataFolderNames = dataDirs.filter {
                LCPath.dataPath.appendingPathComponent($0).hasDirectoryPath
            }
        } catch {
            NSLog("[LC] StandaloneSettingsView: failed to read data folders: \(error)")
        }
        do {
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            model.tweakFolderNames = tweakDirs.filter {
                LCPath.tweakPath.appendingPathComponent($0).hasDirectoryPath
            }
        } catch {
            NSLog("[LC] StandaloneSettingsView: failed to read tweak folders: \(error)")
        }
    }
}
