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
- [~] **Phase 2 — Icon states + context menu + edit mode.** Done: full app
      context menu (Run Single/Parallel with remembered per-app mode, Add to Home
      Screen submenu, Move Cards, Settings-as-sheet, Uninstall), restricted menu
      for default apps, single-mode badge, blue "new" dot, jiggle edit mode with
      Done pill and delete (default apps protected). **Remaining:** drag-to-reorder
      cards (persists to LCAppSortManager custom order) — to be added next.
- [ ] Phase 3 — Install-on-home (progress, cancel, game warning).
- [~] **Phase 4 — Springboard search overlay.** Bottom search pill opens a
      blurred full-screen overlay with a focused search field (magnifier + clear
      that returns home) and an "Installed" results section that launches the
      tapped app. **Remaining:** per-source results (depends on the Installer
      source cache from Phase 6).
- [x] **Phase 5 — List view layout.** Glass rows (icon, name, version·bundle,
      RUN) switched on by Personalization → List. Shares context menu / tap /
      delete with the grid. (Row drag-reorder pending with grid reorder.)
- [ ] Phase 6 — Installer rework (source carousel, sources popup, import menu).
- [ ] Phase 7 — Categorized Settings + UDID/Premium card.
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
