# Luma

A tiny macOS menu bar app for Apple Silicon MacBooks that disconnects the built-in display while keeping the lid open, so you can use only an external monitor and still use the MacBook camera, microphone, keyboard, trackpad, and Touch ID.

> [!WARNING]
> Luma uses undocumented/private SkyLight APIs (`SLSConfigureDisplayEnabled` and `SLSGetDisplayList`). It is intended for Apple Silicon Macs and may break after a macOS update.

## Features

- Menu bar only — no Dock icon
- Turn the built-in display on/off with one click
- Refuses to turn off the built-in display when no external display is active
- Optional **Auto-disable with External Display** mode
- Fail-safe: if the external display disappears while the built-in panel is disabled, Luma attempts to turn the built-in panel back on
- No third-party runtime dependencies
- Apple Silicon (`arm64`) only
- macOS 13+

## Download

Open **Releases** and download `Luma-macOS-arm64.zip` from the newest release. Unzip it and move `Luma.app` to `/Applications` if you want.

The CI build is ad-hoc signed, not notarized with an Apple Developer ID. On first launch macOS may require **right click → Open**. If Gatekeeper still blocks the app, you can remove quarantine after reviewing the source:

```bash
xattr -dr com.apple.quarantine /Applications/Luma.app
```

## Usage

1. Keep the MacBook lid open.
2. Connect an external monitor.
3. Launch Luma.
4. Click the menu bar display icon.
5. Choose **Turn Built-in Display Off**.

The built-in camera remains available because the lid stays open; only the built-in display is disconnected from the active display configuration.

### Auto mode

Enable **Auto-disable with External Display** from the menu. Luma will disable the built-in panel when an external display is present and re-enable it when the external display is gone.

## Build locally

Requirements: Xcode Command Line Tools and macOS 13+.

```bash
./scripts/build-app.sh
open dist/Luma.app
```

Or build the Swift executable directly:

```bash
swift build -c release --arch arm64
```

## How it works

CoreGraphics does not expose a public API for disconnecting an individual display. Luma dynamically loads `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` and resolves two private symbols at runtime:

- `SLSConfigureDisplayEnabled` — enables/disables a display inside a CoreGraphics display configuration transaction
- `SLSGetDisplayList` — finds displays that are no longer present in the active/online CoreGraphics display lists

Using `dlopen`/`dlsym` avoids a hard link-time dependency on the private framework, but the API is still private and unsupported by Apple.

## CI / Releases

- `.github/workflows/ci.yml` builds the app on pushes and pull requests.
- `.github/workflows/release.yml` publishes a rolling `dev` prerelease on every push to `main`, so the latest test build is always available from Releases.
- Pushing a version tag such as `v0.1.0` creates a normal versioned release.

## License

MIT
