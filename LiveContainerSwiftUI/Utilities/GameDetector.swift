//
//  GameDetector.swift
//  LiveContainerSwiftUI
//
//  Local-only heuristic for deciding whether a guest app bundle is a game.
//  Designed to be cheap enough to run once at install time: it reads the guest
//  Info.plist, parses only the Mach-O header + load commands (never the whole
//  binary), and does shallow directory checks (never a recursive bundle walk).
//
//  Signals are combined into a score. A few signals are treated as definitive
//  (immediate match); the rest accumulate toward a threshold so ambiguous apps
//  are caught without over-triggering on, say, any app that merely uses Metal.
//

import Foundation

enum GameDetector {

    /// Score at/above which a bundle is treated as a game.
    private static let threshold = 80

    /// Whether the bundle at `bundlePath` appears to be a game. Local only.
    static func isGame(bundlePath: String) -> Bool {
        score(bundlePath: bundlePath) >= threshold
    }

    /// Weighted score across all local signals. Higher = more game-like.
    static func score(bundlePath: String) -> Int {
        let url = URL(fileURLWithPath: bundlePath)
        let fm = FileManager.default
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))

        // --- Definitive Info.plist signals ---
        if let plist {
            if let cat = plist["LSApplicationCategoryType"] as? String,
               cat.localizedCaseInsensitiveContains("game") {
                return 1000
            }
            if (plist["GCSupportsGameMode"] as? Bool) == true { return 1000 }
            if (plist["LSSupportsGameMode"] as? Bool) == true { return 1000 }
        }

        // --- Definitive engine artifacts ---
        if hasEngineArtifacts(url, fm) { return 1000 }

        var score = 0

        // --- Softer Info.plist heuristics ---
        if let plist {
            if (plist["GCSupportsControllerUserInteraction"] as? Bool) == true { score += 60 }
            if (plist["CADisableMinimumFrameDurationOnPhone"] as? Bool) == true { score += 25 }
            if isLandscapeOnly(plist) { score += 20 }
            if (plist["UIRequiresFullScreen"] as? Bool) == true { score += 10 }
        }

        // --- Mach-O linked frameworks ---
        if let exe = executableURL(url, plist: plist) {
            let libs = linkedDylibNames(atPath: exe.path)
            func linksAny(_ names: [String]) -> Bool {
                libs.contains { lib in names.contains { lib.localizedCaseInsensitiveContains($0) } }
            }
            // Apple game frameworks — game-only in practice.
            if linksAny(["SpriteKit", "SceneKit", "GameplayKit"]) { score += 80 }
            // Game Center / controllers.
            if linksAny(["GameKit", "GameController"]) { score += 65 }
            // GPU frameworks — softer (plenty of non-games use Metal).
            if linksAny(["Metal", "OpenGLES"]) { score += 25 }
        }

        // --- Ad / mediation SDKs — overwhelmingly ship in games. ---
        if hasGameAdSDK(url, fm) { score += 80 }

        return score
    }

    // MARK: - Info.plist helpers

    private static func isLandscapeOnly(_ plist: NSDictionary) -> Bool {
        let orients = (plist["UISupportedInterfaceOrientations"] as? [String])
            ?? (plist["UISupportedInterfaceOrientations~ipad"] as? [String])
        guard let orients, !orients.isEmpty else { return false }
        return orients.allSatisfy { $0.localizedCaseInsensitiveContains("Landscape") }
    }

    private static func executableURL(_ bundleURL: URL, plist: NSDictionary?) -> URL? {
        if let exe = plist?["CFBundleExecutable"] as? String, !exe.isEmpty {
            let u = bundleURL.appendingPathComponent(exe)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // Fallback: <Name>.app/<Name>
        let guess = bundleURL.appendingPathComponent(bundleURL.deletingPathExtension().lastPathComponent)
        return FileManager.default.fileExists(atPath: guess.path) ? guess : nil
    }

    // MARK: - Bundle artifact scans (shallow only)

    /// Known files/dirs that pin the app to a specific game engine.
    private static let engineMarkers: [String] = [
        // Unity
        "Data/globalgamemanagers", "Data/boot.config", "Data/il2cpp_data",
        "Data/unity default resources", "Frameworks/UnityFramework.framework",
        // Unreal Engine
        "cookeddata", "UE4CommandLine.txt",
        // GameMaker
        "data.win", "game.ios", "game.unx",
        // Defold
        "game.projectc", "game.arci", "game.arcd",
        // Solar2D / Corona
        "resource.car",
        // RPG Maker MV / MZ
        "www/js/rpg_core.js", "www/js/rmmz_core.js",
        // Ren'Py
        "renpy",
    ]

    private static func hasEngineArtifacts(_ bundleURL: URL, _ fm: FileManager) -> Bool {
        for marker in engineMarkers {
            if fm.fileExists(atPath: bundleURL.appendingPathComponent(marker).path) { return true }
        }
        // Shallow bundle-root scan for extension/prefix markers. Deliberately not
        // matching bare *.pak (Chromium-based apps ship resource .pak files).
        if let contents = try? fm.contentsOfDirectory(atPath: bundleURL.path) {
            for name in contents {
                let lower = name.lowercased()
                if lower.hasSuffix(".pck")           // Godot
                    || lower.hasSuffix(".love")      // LÖVE
                    || lower.hasPrefix("libcocos") { // Cocos2d-x
                    return true
                }
            }
        }
        return false
    }

    /// Ad / mediation SDKs that are almost exclusive to games. Generic ones used
    /// widely by non-games (AdMob/GoogleMobileAds, Firebase) are intentionally
    /// excluded to avoid false positives.
    private static let adSDKMarkers: [String] = [
        "AppLovin", "IronSource", "UnityAds", "Vungle", "AdColony", "Chartboost",
        "Mintegral", "MTGSDK", "Pangle", "PAGAdSDK", "Tapjoy", "Fyber",
    ]

    private static func hasGameAdSDK(_ bundleURL: URL, _ fm: FileManager) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        guard let contents = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        for name in contents {
            for sdk in adSDKMarkers where name.localizedCaseInsensitiveContains(sdk) {
                return true
            }
        }
        return false
    }

    // MARK: - Mach-O parsing (header + load commands only)

    /// Leaf names of the dylibs the Mach-O at `path` links (e.g. "Metal",
    /// "SpriteKit", "UnityFramework"). Reads only the header and load commands —
    /// the first few KB — never the whole binary. Handles thin and fat binaries.
    /// Returns [] on any parse issue.
    private static func linkedDylibNames(atPath path: String) -> Set<String> {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        func read(_ count: Int, at offset: UInt64) -> Data? {
            do {
                try fh.seek(toOffset: offset)
                let d = fh.readData(ofLength: count)
                return d.count == count ? d : nil
            } catch { return nil }
        }
        func u32(_ d: Data, _ o: Int, _ bigEndian: Bool) -> UInt32 {
            let s = d.startIndex.advanced(by: o)
            let b0 = UInt32(d[s]), b1 = UInt32(d[s + 1]), b2 = UInt32(d[s + 2]), b3 = UInt32(d[s + 3])
            let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            return bigEndian ? v.byteSwapped : v
        }

        guard let magicData = read(4, at: 0) else { return [] }
        let beMagic = u32(magicData, 0, true)   // fat headers are big-endian

        // Locate the Mach-O slice (0 for thin; the arm64 slice for fat).
        var machOffset: UInt64 = 0
        if beMagic == 0xcafebabe || beMagic == 0xcafebabf {
            let is64 = (beMagic == 0xcafebabf)
            guard let fatHdr = read(8, at: 0) else { return [] }
            let nfat = u32(fatHdr, 4, true)
            let archSize = is64 ? 32 : 20
            var firstOffset: UInt64?
            var arm64Offset: UInt64?
            for i in 0..<Int(min(nfat, 32)) {
                let base = UInt64(8 + i * archSize)
                guard let arch = read(archSize, at: base) else { break }
                let cputype = u32(arch, 0, true)
                let offset: UInt64
                if is64 {
                    offset = (UInt64(u32(arch, 8, true)) << 32) | UInt64(u32(arch, 12, true))
                } else {
                    offset = UInt64(u32(arch, 8, true))
                }
                if firstOffset == nil { firstOffset = offset }
                if cputype == 0x0100000c { arm64Offset = offset }   // CPU_TYPE_ARM64
            }
            machOffset = arm64Offset ?? firstOffset ?? 0
        }

        // Mach-O header.
        guard let hdr = read(32, at: machOffset) else { return [] }
        let magic = u32(hdr, 0, false)
        let is64: Bool, swap: Bool
        switch magic {
        case 0xfeedfacf: (is64, swap) = (true, false)   // MH_MAGIC_64
        case 0xcffaedfe: (is64, swap) = (true, true)    // MH_CIGAM_64
        case 0xfeedface: (is64, swap) = (false, false)  // MH_MAGIC
        case 0xcefaedfe: (is64, swap) = (false, true)   // MH_CIGAM
        default: return []
        }
        let ncmds = u32(hdr, 16, swap)
        let sizeofcmds = u32(hdr, 20, swap)
        guard sizeofcmds > 0, sizeofcmds < 8_000_000 else { return [] }
        let cmdsStart = machOffset + (is64 ? 32 : 28)
        guard let cmds = read(Int(sizeofcmds), at: cmdsStart) else { return [] }

        var result = Set<String>()
        var cursor = 0
        for _ in 0..<Int(min(ncmds, 8000)) {
            guard cursor + 8 <= cmds.count else { break }
            let cmd = u32(cmds, cursor, swap)
            let cmdsize = Int(u32(cmds, cursor + 4, swap))
            guard cmdsize >= 8, cursor + cmdsize <= cmds.count else { break }
            // LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB
            if cmd == 0x0c || cmd == 0x80000018 || cmd == 0x8000001f {
                let nameOffset = Int(u32(cmds, cursor + 8, swap))
                if nameOffset >= 8, cursor + nameOffset < cursor + cmdsize {
                    let s = cmds.startIndex.advanced(by: cursor + nameOffset)
                    let e = cmds.startIndex.advanced(by: cursor + cmdsize)
                    var bytes = [UInt8](cmds[s..<e])
                    if let nul = bytes.firstIndex(of: 0) { bytes = Array(bytes[0..<nul]) }
                    let full = String(decoding: bytes, as: UTF8.self)
                    result.insert((full as NSString).lastPathComponent)
                }
            }
            cursor += cmdsize
        }
        return result
    }
}
