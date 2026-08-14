//
//  AccessVerification.swift
//  LiveContainer
//
//  Device access (ban) verification against the FlekSt0re status service,
//  plus the cached verdict that lets the app start without a network round trip.
//

import Foundation

/// Outcome of a single access check.
///
/// The two failure cases are deliberately distinct. `unreachable` means the
/// request never made it to the server (offline, DNS, TLS, timeout) and says
/// nothing about the user; `serviceError` means the server answered with
/// something we could not interpret. Neither is evidence of a ban, so neither
/// locks anyone out on its own — only an explicit banned verdict does that.
enum AccessCheckResult {
    /// The server answered; `response.isBanned` decides access.
    case answered(DeviceStatusResponse)
    case unreachable
    case serviceError
}

/// A previously fetched verdict, persisted so launching does not require a
/// network round trip.
struct CachedAccessVerdict {
    let isBanned: Bool
    let banReason: String?
    let banMessage: String?
    let checkedAt: Date
    let graceWindow: TimeInterval

    /// Inside the refresh interval the verdict is used as-is and no request is
    /// made at all. This is the common launch path.
    func isFresh(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(checkedAt) < AccessVerdictStore.refreshInterval
    }

    /// Past the grace window a clean verdict is no longer trusted, and access
    /// must be re-verified online before the app opens.
    func isWithinGraceWindow(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(checkedAt) < graceWindow
    }
}

/// Persistence for the access verdict.
///
/// The gate is intentionally asymmetric: a ban is sticky and applies offline,
/// while a clean verdict grants a grace window during which the app opens with
/// no server contact. Users routinely run their apps with no connectivity — on
/// a plane, or abroad without roaming — and offline use costs the service
/// nothing, since every network-backed feature is already unusable there.
enum AccessVerdictStore {
    /// A clean verdict is re-checked in the background once it reaches this age.
    /// Until then the app does not contact the server at all.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// How long a clean verdict keeps opening the app with no successful check.
    static let defaultGraceWindow: TimeInterval = 3 * 24 * 60 * 60

    /// Ceiling for a server-supplied window, so a bad payload cannot grant
    /// unlimited offline access.
    private static let maximumGraceWindow: TimeInterval = 30 * 24 * 60 * 60

    /// NTP corrections move the clock by seconds. Anything beyond this reads as
    /// a deliberate change.
    private static let clockDriftTolerance: TimeInterval = 5 * 60

    private static var defaults: UserDefaults { LCUtils.appGroupUserDefault }

    private enum Key {
        static let udid = "FSAccessVerdictUDID"
        static let isBanned = "FSAccessVerdictIsBanned"
        static let banReason = "FSAccessVerdictBanReason"
        static let banMessage = "FSAccessVerdictBanMessage"
        static let checkedAt = "FSAccessVerdictCheckedAt"
        static let graceWindow = "FSAccessVerdictGraceWindow"
        static let clockHighWaterMark = "FSAccessClockHighWaterMark"
    }

    static func load(for encryptedUDID: String, asOf now: Date = Date()) -> CachedAccessVerdict? {
        // A verdict belongs to the device it was issued for.
        guard defaults.string(forKey: Key.udid) == encryptedUDID else {
            return nil
        }

        let checkedAtRaw = defaults.double(forKey: Key.checkedAt)
        guard checkedAtRaw > 0 else {
            return nil
        }
        let checkedAt = Date(timeIntervalSince1970: checkedAtRaw)

        // Winding the date back would otherwise stretch the grace window
        // indefinitely. A discarded verdict falls through to an online check,
        // which is the strict path — so this cannot be used to escape a ban.
        guard !hasClockRolledBack(asOf: now),
              now >= checkedAt.addingTimeInterval(-clockDriftTolerance) else {
            return nil
        }

        return CachedAccessVerdict(
            isBanned: defaults.bool(forKey: Key.isBanned),
            banReason: defaults.string(forKey: Key.banReason),
            banMessage: defaults.string(forKey: Key.banMessage),
            checkedAt: checkedAt,
            graceWindow: storedGraceWindow()
        )
    }

    /// Clamped on read as well as on write. The backing store is a plain
    /// UserDefaults plist, so a value that did not come from `save` — a
    /// hand-edited container, a guest app sharing this sandbox — must not be
    /// able to hand itself a window of its own choosing.
    ///
    /// Reads `object(forKey:)` rather than `double(forKey:)` so that an explicit
    /// zero, the server's strict-mode switch, stays distinct from "never
    /// stored", which falls back to the default.
    private static func storedGraceWindow() -> TimeInterval {
        guard let stored = defaults.object(forKey: Key.graceWindow) as? Double else {
            return defaultGraceWindow
        }
        return min(max(stored, 0), maximumGraceWindow)
    }

    static func save(_ response: DeviceStatusResponse, for encryptedUDID: String, asOf now: Date = Date()) {
        defaults.set(encryptedUDID, forKey: Key.udid)
        defaults.set(response.isBanned, forKey: Key.isBanned)
        defaults.set(response.banReason, forKey: Key.banReason)
        defaults.set(response.message, forKey: Key.banMessage)
        defaults.set(now.timeIntervalSince1970, forKey: Key.checkedAt)
        defaults.set(graceWindow(fromDays: response.offlineGraceDays), forKey: Key.graceWindow)

        // A successful check is ground truth, so it also rebases the tamper
        // baseline. Without this, a device whose clock was once wrong in the
        // future would keep failing the rollback test after the clock is
        // corrected, and could never use its grace window again.
        defaults.set(now.timeIntervalSince1970, forKey: Key.clockHighWaterMark)
    }

    /// The server may narrow or widen the offline window without an app update.
    /// A value of zero restores strict behaviour: every launch needs a check.
    private static func graceWindow(fromDays days: Int?) -> TimeInterval {
        guard let days else {
            return defaultGraceWindow
        }
        return min(max(TimeInterval(days) * 24 * 60 * 60, 0), maximumGraceWindow)
    }

    /// The wall clock only moves forward in normal use, so the highest reading
    /// ever seen acts as a floor. A current time meaningfully below that floor
    /// means the date was set by hand — the one cheap way to abuse an offline
    /// grace window.
    @discardableResult
    private static func hasClockRolledBack(asOf now: Date) -> Bool {
        let highWaterMark = defaults.double(forKey: Key.clockHighWaterMark)
        let nowRaw = now.timeIntervalSince1970

        if highWaterMark > 0, nowRaw < highWaterMark - clockDriftTolerance {
            return true
        }
        if nowRaw > highWaterMark {
            defaults.set(nowRaw, forKey: Key.clockHighWaterMark)
        }
        return false
    }
}

enum AccessVerificationService {
    /// This check blocks the UI, so a hung request is worse than a failed one:
    /// the default 60s timeout can park a user on a spinner for a full minute
    /// behind a captive portal. Caching is disabled so a stored 200 cannot mask
    /// a ban being applied or lifted.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func fetchStatus(encryptedUDID: String) async -> AccessCheckResult {
        guard let url = URL(
            string: "https://nestapi.flekstore.com/device-service/get-status/\(encryptedUDID)"
        ) else {
            return .serviceError
        }

        do {
            let (data, response) = try await session.data(from: url)

            // Every field of DeviceStatusResponse decodes with a default, so
            // without this any JSON at all — a 404 body, a 500 page, a captive
            // portal's reply — would decode as "not banned" and then be cached
            // as a clean verdict. An answer we did not ask for is not evidence
            // of anything, so it is treated as no answer.
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return .serviceError
            }

            return .answered(try JSONDecoder().decode(DeviceStatusResponse.self, from: data))
        } catch is URLError {
            return .unreachable
        } catch {
            return .serviceError
        }
    }
}
