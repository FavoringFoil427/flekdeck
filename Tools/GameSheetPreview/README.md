# GameSheetPreview

A throwaway simulator app for eyeballing the "Recommended for games" sheet
([FlekGameWarningView.swift](../../LiveContainerSwiftUI/FlekLauncher/Home/FlekGameWarningView.swift))
on different iOS runtimes, without building all of LiveContainer.

```bash
./run.sh 17     # iOS 17.x simulator
./run.sh 26     # iOS 26.x simulator
```

`Sources/FlekGameWarningView.swift` is a copy of the production view. Everything
down to the `// --- harness-only` comment is identical to the shipping code, so
what you see is what the app renders. Below that comment is a `skin` switch that
swaps the sheet's background treatment:

| # | Skin | What it does |
|---|------|--------------|
| 0 | Shipping | current behaviour: `.clear` on iOS 26+, `.regularMaterial` below |
| 1 | Legacy clear | the old behaviour, `.clear` on everything from iOS 16.4 up |
| 2 | System default | no `presentationBackground` override; the standard sheet chrome |
| 3 | Flek glass | mirrors `FlekGlassBackground` (ultraThin + 22% white + hairline border) |
| 4 | Regular material | `.regularMaterial` on every version, including iOS 26 |
| 5 | Opaque | `presentationBackground(Color(.systemBackground))` |
| 6 | iOS 15 path | no detents, no indicator, no background — the view's final `else` branch |

Skin 6 exists because there is usually no iOS 15 runtime to install. A sheet with
no detents on a modern runtime lays out the same way an iOS 15 page sheet does,
so it shows that branch without an iOS 15 simulator.

Pick one in the wheel and tap **Show sheet**, or drive it by URL so screenshots
can be scripted:

```bash
xcrun simctl openurl booted gspreview://variant/1
```

The backdrop behind the sheet is a fake springboard (wallpaper gradient plus a
grid of frosted app tiles) — a plain background would hide exactly the problem
you are looking for.

Deployment target is iOS 17.0, so one binary runs on every installed runtime.
That also makes the view's `#available(iOS 16.0, *)` branch dead code here; the
compiler warning about it is expected, and the branch is kept only so the copy
stays faithful to production.
