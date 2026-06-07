# FlekSign Redesign — Progress

Reworking LiveContainer into the **FlekLauncher** springboard design from the
Figma file `FlekSign` (`paCG8NHeIWaCsxJ8ThkcEw`). Multitasking is intentionally
**out of scope** for this pass (switcher bar, navigation assist, multitasking
menu, switcher dock — not touched).

New launcher code lives under `LiveContainerSwiftUI/FlekLauncher/`.

## Design decisions (confirmed with user)
- **FlekSt0re** home icon → opens the Installer with the FlekSt0re source pre-selected.
- Default apps (Settings / Installer) open as **full-screen covers** (no multitasking
  switcher bar). Regular apps launch exactly as before.
- Apps render as **frosted glass cards** (3-column grid) — taken from the only
  fully-structured Figma frame (`Homescreen-empty`); the 4-column raster mockups
  are non-authoritative.

## Phases
- [x] **Phase 1 — Springboard shell.** Wallpaper, paged 3-column card grid
      (default apps + installed apps), bottom search pill, page dots. Tabs removed.
      Settings/Installer open as full-screen covers; installed apps launch via the
      existing engine (reused from `LCAppListView`).
- [x] **Phase 2 — Icon states + context menu + edit mode.** Full app context
      menu (Run Single/Parallel with remembered per-app mode, Add to Home Screen
      submenu, Move Cards, Settings-as-sheet, Uninstall), restricted menu for
      default apps, single-mode badge, blue "new" dot, jiggle edit mode with Done
      pill, delete (default apps protected), and drag-to-reorder (persists to
      LCAppSortManager custom order).
- [x] **Phase 3 — Install-on-home + game warning.** Installing app shows a frosted progress card on the home (icon, name, progress, cancel via DownloadHelper). Game launch shows a "Recommended for games" sheet (Run Single vs Run Parallel, remember-my-choice default on) wired to the per-app launch-mode store.
- [x] **Phase 4 — Springboard search overlay.** Bottom-bar search field (above
      the keyboard) over the dimmed/blurred home, with "Installed" results
      (launch on tap) and a "FlekSt0re" section (server-side search, install on
      tap); clear/close returns home.
- [x] **Phase 5 — List view layout.** Glass rows (icon, name, version·bundle,
      RUN) switched on by Personalization → List. Shares context menu / tap /
      delete with the grid. (Row drag-reorder pending with grid reorder.)
- [x] **Phase 6 — Installer rework.** New FlekInstallerView: source carousel + manage-sources popup (add/select/delete with confirm, FlekSt0re protected), category switcher, redesigned app rows with download, bottom Import-IPA menu + search + back-to-home chevron. Reuses FlekstoreAppsListViewModel + saved-repositories store; installs via sharedModel.urlToInstall.
- [x] **Phase 7 — Categorized Settings.** LCSettingsView reworked into the design: UDID + Premium card, a category group (Personalization, Launch Behavior, Multitask Mode, JIT & JIT-Less, Content Restrictions, Signing & Installation, Tweaks) each drilling into a focused page, and a links/about group. Icon-appearance toggles moved to the Personalization page. All existing controls/logic/alerts reused.
- [x] **Phase 8 — Personalization page + wallpapers popup + grid/list toggle.**
      New Personalization page (reachable from Settings): current-wallpaper
      preview, Choose from Collection (bundled default + gradient presets),
      Choose from Photos (PHPicker, saved to app group), and the Grid/List
      home-layout switch. Wallpaper drives the home background live.

## Architecture notes
- `LCAppListView` was repurposed as the springboard host: it keeps ALL of the
  proven launch/install/JIT/deep-link machinery (it conforms to
  `LCAppModelDelegate`/`LCAppBannerDelegate`); only its visual body was swapped
  for `FlekSpringboardView`.
- `LCTabView` is now a thin gate (blocked-status check + lifecycle) around the
  springboard — no `TabView`.
- App settings (per-app) now presents via `.sheet` (swipe-to-dismiss) using the
  existing `openNavigationView`/`closeNavigationView` delegate hooks.

## Build / test
Cannot run in simulator (sideload/JIT). Pre-commit check is a compile:
`xcodebuild build -scheme LiveContainerSwiftUI -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
Requires `git submodule update --init --recursive` (litehook/OpenSSL).
Real runtime testing is done by the user on a device.
