//
//  AppOrientation.swift
//  LiveContainerSwiftUI
//
//  Reads a guest app's declared interface orientations from its Info.plist.
//  Note this is the app's *declared* support (UISupportedInterfaceOrientations);
//  apps can still override at runtime, but for most apps — and games especially —
//  it matches how they actually run.
//

import UIKit

enum AppOrientation {

    /// True if the app declares only landscape orientations (i.e. it's meant to run
    /// horizontally). Returns false when it also supports portrait, or when no
    /// orientations are declared (absent = the app permits all).
    static func isLandscapeOnly(bundlePath: String) -> Bool {
        let plistURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else { return false }

        let base = plist["UISupportedInterfaceOrientations"] as? [String]
        let pad = plist["UISupportedInterfaceOrientations~ipad"] as? [String]
        // Prefer the key matching the current device idiom.
        let orientations = (UIDevice.current.userInterfaceIdiom == .pad ? (pad ?? base) : (base ?? pad))

        guard let orientations, !orientations.isEmpty else { return false }
        let hasPortrait = orientations.contains { $0.contains("Portrait") }
        let hasLandscape = orientations.contains { $0.contains("Landscape") }
        return hasLandscape && !hasPortrait
    }
}
