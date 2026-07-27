//
//  GameDetector.swift
//  LiveContainerSwiftUI
//
//  Local-only heuristic for deciding whether a guest app bundle is a game.
//  Cheap enough to run once at install time: it reads the guest Info.plist and
//  does shallow directory checks only (never a recursive bundle walk).
//
//  Precision-first. LiveContainer runs *repackaged* IPAs, which routinely strip
//  metadata (including LSApplicationCategoryType) — so detection must lean on
//  signals that are both game-specific and survive repackaging. Framework linkage
//  (SpriteKit/SceneKit/GameKit/GameController/Metal, via Mach-O) was deliberately
//  removed: mainstream non-game apps link those too (Instagram/Twitter link
//  SpriteKit for effects, AR apps link SceneKit, etc.), so it produced false
//  positives that a stripped category couldn't override.
//
//  Pure custom-engine games that ship none of the signals below are better handled
//  by an authoritative bundle-id lookup (future work) than by noisy local guesses.
//

import Foundation

enum GameDetector {

    /// Bump whenever the detection logic changes, so a cached `LCIsGame` result
    /// stored under an older version is recomputed instead of trusted.
    static let detectorVersion = 7

    /// Known mainstream non-game apps, matched by bundle id (exact). Checked first
    /// so no heuristic can flag them. Modders sometimes change the bundle id, so
    /// this is backed up by `nonGameNameKeywords` below.
    private static let knownNonGameBundleIDs: Set<String> = [
        // Social & messaging
        "com.burbn.instagram", "net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB",
        "com.facebook.Facebook", "com.facebook.Messenger", "com.atebits.Tweetie2",
        "com.zhiliaoapp.musically", "com.toyopagroup.picaboo", "ph.telegra.Telegraph",
        "org.whispersystems.signal", "com.hammerandchisel.discord", "com.reddit.Reddit",
        "pinterest", "com.linkedin.LinkedIn", "com.tencent.xin", "com.burbn.barcelona",
        "jp.naver.line", "com.kakao.talk",
        // Google & productivity
        "com.google.ios.youtube", "com.google.Gmail", "com.google.Maps",
        "com.google.chrome.ios", "com.google.GoogleMobile", "com.google.Drive",
        "com.google.photos", "com.microsoft.Office.Outlook", "com.microsoft.skype.teams2",
        "com.tinyspeck.chatlyio", "com.getdropbox.Dropbox", "notion.id",
        "us.zoom.videomeetings",
        // Streaming & media
        "com.netflix.Netflix", "com.spotify.client", "com.google.ios.youtubemusic",
        "com.disney.disneyplus", "tv.twitch", "com.amazon.aiv.AIVApp", "com.hulu.plus",
        "com.soundcloud.TouchApp", "com.shazam.Shazam",
        // Shopping & finance
        "com.amazon.Amazon", "com.squareup.cash", "net.kortina.labs.Venmo",
        "com.ebay.iphone", "com.alibaba.iAliexpress", "com.paypal.ppmobile",
        // Transport, travel & dating
        "com.ubercab.UberClient", "com.zimride.instant", "com.airbnb.app",
        "com.booking.Booking", "com.cardify.tinder", "com.bumble.app",
    ]

    /// Distinctive brand keywords for a normalized "contains" match on the display
    /// name — catches renamed mods (e.g. "Instagram Rocket", "WhatsApp Plus") whose
    /// bundle id was changed. Deliberately only unambiguous roots (≥5 letters) that
    /// are very unlikely to appear inside a real game's name; short/common words
    /// (uber → "Ubermosh", zoom, signal, x, line, cash…) are excluded on purpose.
    private static let nonGameNameKeywords: [String] = [
        // Mainstream brands.
        "instagram", "whatsapp", "facebook", "messenger", "snapchat", "telegram",
        "discord", "reddit", "pinterest", "linkedin", "wechat", "threads", "tiktok",
        "twitter", "kakaotalk", "youtube", "gmail", "chrome", "dropbox", "notion",
        "outlook", "netflix", "spotify", "disneyplus", "twitch", "soundcloud",
        "shazam", "aliexpress", "airbnb", "tinder", "bumble",
        // Non-game apps hand-picked from the FlekStore top-downloads list (editors,
        // media players, utilities). Emulators are intentionally excluded — they are
        // game-like and should still show the launch-mode prompt.
        "capcut", "adobe", "lightroom", "lumafusion", "inshot", "bazaart",
        "motionleap", "procreate", "afterlight", "instories", "enhancefox",
        "zoomerang", "procam", "focos", "infuse", "filza", "itorrent",
        "truecaller", "myfitnesspal", "sleepcycle", "duolingo", "nicegram",
        "busuu", "flightradar", "radarbot", "moises", "planta", "purekfd",
        "purepkg", "trolltools",
    ]

    /// Whether the bundle at `bundlePath` appears to be a game. Local only.
    static func isGame(bundlePath: String) -> Bool {
        let url = URL(fileURLWithPath: bundlePath)
        let fm = FileManager.default
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))

        // 0. Known mainstream non-game apps — never a game, override all heuristics.
        //    Match by bundle id (exact) or a distinctive brand keyword in the
        //    display name (catches renamed mods with a changed bundle id).
        if let bid = plist?["CFBundleIdentifier"] as? String,
           knownNonGameBundleIDs.contains(bid) {
            return false
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            guard let name = plist?[key] as? String else { continue }
            let normalized = name.lowercased().filter { $0.isLetter }
            if nonGameNameKeywords.contains(where: { normalized.contains($0) }) {
                return false
            }
        }

        let category = plist?["LSApplicationCategoryType"] as? String
        let hasCategory = !(category?.isEmpty ?? true)

        // 1. Explicit game category (covers `public.app-category.games` and every
        //    game subcategory, all of which contain "game").
        if category?.localizedCaseInsensitiveContains("game") == true {
            return true
        }

        // 2. Deliberate, game-specific Info.plist declarations. Checked before the
        //    non-game-category shortcut below so an emulator categorized as e.g.
        //    "Utilities" that declares controller support is still caught.
        if let plist {
            if (plist["GCSupportsGameMode"] as? Bool) == true { return true }
            if (plist["LSSupportsGameMode"] as? Bool) == true { return true }
            if (plist["GCSupportsControllerUserInteraction"] as? Bool) == true { return true }
        }

        // 3. A present non-game category is authoritative: Apple tags real games as
        //    "games", so any other category (Photo & Video, Social Networking,
        //    Utilities, …) means not a game. Trust it over the engine/ad-SDK
        //    heuristics below — those exist only for repackaged apps whose category
        //    was stripped.
        if hasCategory { return false }

        // 4. No category to trust → fall back to bundle heuristics.
        if hasEngineArtifacts(url, fm) { return true }   // Unity/Unreal/Godot/Cocos/…
        if hasGameAdSDK(url, fm) { return true }          // AppLovin/IronSource/Vungle/…

        return false
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
    /// widely by non-games (AdMob/GoogleMobileAds, Firebase, Facebook Audience
    /// Network) are intentionally excluded to avoid false positives.
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
}
