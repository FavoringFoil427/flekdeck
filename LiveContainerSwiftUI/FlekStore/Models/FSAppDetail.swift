//
//  FSAppDetail.swift
//  LiveContainerSwiftUI
//
//  The full app page from `GET https://nestapi.flekstore.com/app/{app_id}` —
//  developer, screenshots, description, size, downloads and release date. The
//  catalog list endpoint returns none of this, so it is fetched on demand when
//  a row is opened.
//

import Foundation

struct FSAppDetail: Codable {
    let id: Int
    let icon: String?
    let name: String?
    let developer: String?
    let version: String?
    let photos: [String]?
    /// Advisory shown above the stats — a setup caveat for this particular app.
    /// The API sends an empty string when there is nothing to say.
    let warning: String?
    /// HTML from a rich-text editor, not plain text — parsed for display by
    /// `FSDescriptionParser`.
    let description: String?
    let downloads: Int?
    /// Bytes.
    let size: Int64?
    /// ISO-8601 with fractional seconds, e.g. "2026-08-12T19:33:00.000Z".
    let date: String?
    let isAdult: Bool?

    // NOTE: the response also carries `install_url`, but unlike the list
    // endpoint's it is a bare filename ("alienInvasion.ipa") rather than a URL.
    // Installs therefore always go through the `FSAppModel` the row was built
    // from, which holds the real download URL.

    // MARK: Display

    var warningText: String? {
        guard let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines),
              !warning.isEmpty else { return nil }
        return warning
    }

    var formattedSize: String? { FSCatalogFormat.size(bytes: size) }

    var formattedDate: String? { FSCatalogFormat.date(date) }

    var formattedDownloads: String? {
        guard let downloads, downloads > 0 else { return nil }
        return String(downloads)
    }
}
