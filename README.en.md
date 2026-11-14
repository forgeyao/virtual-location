<img src="assets/brand/logo-preview.png" width="96" alt="Virtual Location logo">

# Virtual Location · 虚拟定位

[中文](README.md) | English

A native macOS app for selecting, changing, and restoring an iPhone's simulated location over USB. The interface uses SwiftUI and MapKit; a separate Python process uses pymobiledevice3 for device communication.

Current desktop version: **0.2.3**. This is a source-built development app. Its generated `.app` still requires the checkout and Python environment.

## Features

- **Map selection and search:** select on the map, enter coordinates, or search for a place. Includes search suggestions, clear search, recenter, and preservation of map zoom when selecting a point.
- **Coordinate systems:** typed input defaults to GCJ-02, with WGS84 available in Settings. Map results and favorites retain their coordinate provenance and are adapted to device GPS coordinates before sending.
- **Random offset** is off by default. Choose 30, 50, 100, or 200 meters. The app remembers the toggle and range across launches. The range is the side length of a square centered on the selected point. A 200 m square extends 100 m in each direction along both axes. Each click samples a fresh point around the original selection.
- **Favorites:** save up to five locations, rename or delete them, and display newest first. At capacity, confirm replacement of the oldest favorite.
- **Connection and recovery:** automatically discover a USB iPhone, show preparation stages and errors, restore location, keep pending-cleanup markers, and export diagnostics from Settings.
- **Appearance and language:** system/light/dark appearance, Chinese/English, and a menu-bar entry for reopening the window.
- **Isolated preview:** a simulated device uses the same backend protocol without accessing a phone or Apple signing.

## Requirements and validation scope

| Component | Current requirement or validation scope |
| --- | --- |
| Mac | Validated on Apple Silicon; deployment target is macOS 14+, but the minimum OS and Intel Macs have not been individually validated |
| Swift | Swift 6 toolchain; locally validated with Swift 6.4.2 |
| Python | 3.14, constrained to `>=3.14,<3.15` |
| Dependency manager | [uv](https://docs.astral.sh/uv/getting-started/installation/), installing from `uv.lock` |
| iPhone | Only iOS 26.x is enabled; tested device: iPhone 13 / iOS 26.6 |
| Connection | USB, trust this computer, unlock the phone, and enable Developer Mode |

Device testing covers setting a fixed position, clearing it with observed recovery, and comparing map selection with fresh phone location samples at public landmarks. Other devices, OS versions, regions, long sessions, lock-screen behavior, and disconnection scenarios need separate validation. Random offsets have mathematical, model, and UI checks but no separate device acceptance test yet. Routes, GPX, and continuous movement are outside the current feature set.

## Build and preview

Get the source:

```sh
git clone https://github.com/forgeyao/virtual-location.git
cd virtual-location
```

Install Xcode Command Line Tools and uv, then run from the repository root:

```sh
xcode-select --install  # Skip if already installed
sh scripts/setup.sh
sh scripts/build-app.sh
```

`setup.sh` uses `uv sync --frozen` to create the project's `.venv`; it does not install into the system Python environment. Initial dependency installation needs a network connection. Building uses local ad hoc signing and does not send device hardware identifiers to Apple.

Start with a simulated-device preview:

```sh
open dist/虚拟定位.app --args --preview
```

Preview mode does not access a real phone. Maps and search may still use the network. If an app process is already running, quit fully with the application menu or `⌘Q` before launching with preview arguments.

The build script uses SwiftPM's `--build-system native` for current toolchain compatibility. This flag is deprecated and may need adjustment after a toolchain update. More details are available in the [Chinese user guide](docs/使用与验证.md).

## Connect a real iPhone

**The current desktop app has no separate Apple-signing consent dialog.** Normal mode automatically prepares an attached device. If a personalized developer image is needed, it sends device hardware identifiers and a nonce to Apple's official signing service. Read “Privacy and network access” below and accept this behavior before connecting a device and launching normal mode. Use `--preview` to inspect the interface without device access.

```sh
open dist/虚拟定位.app
```

1. Connect the iPhone over USB, unlock it, trust the computer, and enable Developer Mode as required by iOS.
2. Wait for the green **iPhone Connected** status. If multiple devices are attached, the first device in a stable ordering is selected.
3. Search, select a map point, or enter coordinates. For GPS/WGS84 input, select WGS84 in Settings first. Optionally enable a random offset and choose its range.
4. Click **Change Location**. The teal **Location Change Sent** status confirms the request was sent; check the actual location in Maps on the phone.
5. Click **Restore Location**, then confirm that the phone returns to its real location.

Connecting or reconnecting does not reapply the previous target. A pending session is cleared first when possible. Closing the window keeps the app running; quitting attempts cleanup. **Unplugging USB does not guarantee immediate restoration.** Reconnect, restore, and verify on the phone. The desktop app does not automatically restore after 90 seconds; timed CLI tests are a separate workflow.

After an update, quit and reopen fully. Closing and reopening only the window can leave an older process running. Rebuild after moving the checkout. The generated `dist/虚拟定位.app` is not a standalone distributable.

## Coordinate handling

Choose GCJ-02 or WGS84 according to the source of the numbers. A location in China, or the Apple Maps brand alone, does not establish identical coordinate semantics across every entry point. Map and search results are checked for provenance; uncertain results are blocked rather than silently guessed. Favorites store their coordinate system, and older untagged favorites require confirmation.

Random offsets are computed in ground meters after adapting the selection to WGS84. Input fields, the original pin, favorites, and camera stay unchanged. Within the supported ranges, the short-distance spherical calculation differs from ellipsoidal distance by less than one meter; this is not a guarantee of actual phone-location accuracy.

## Privacy and network access

| Operation | Data and destination |
| --- | --- |
| Maps, place search, and coordinate-source checks | Handled by Apple MapKit / Core Location services; search terms, relevant coordinates, and map regions may be sent to those services |
| Developer image download | Downloads from the public GitHub mirror configured in the source, caching in `.state/ddi/` |
| Apple personalization signing | Sends required hardware identifiers, such as ECID and chip/board identifiers, plus a nonce to `gs.apple.com` over HTTPS with certificate verification |
| Local storage | `.state/` contains favorite coordinates, preferences, recovery markers, and diagnostic/signing caches that may contain device information; do not publish it |

The project implements no custom telemetry or advertising service and does not request an Apple account password. Signing requests do not include target coordinates; map requests are a separate data flow. An appropriate mounted image skips signing, but a reboot or developer-support change can require signing again. It is not necessarily a one-time operation. See the [developer image notes, in Chinese](docs/开发镜像说明.md).

The CLI requires an explicit flag to permit Apple signing:

```sh
# Read-only discovery; derived device identifiers are still not suitable for public logs
sh scripts/device.sh doctor

# Prepare the device, requesting signing if needed; does not set a target location
sh scripts/device.sh --allow-apple-signing prepare
```

## Development and checks

```sh
.venv/bin/python -m pytest -q
sh scripts/check-swift.sh

# Native map-click checks: opens test windows, never accesses a phone; maps may use the network
sh scripts/check-map-clicks.sh

# Full simulated backend flow, without real-device access
dist/虚拟定位.app/Contents/MacOS/VirtualLocation --preview --ui-smoke

# Inspect Git publication candidates without printing matched sensitive values
python3 scripts/check-publication.py
```

Offline and simulated checks do not replace device acceptance testing. `.gitignore` excludes local state, build output, environments, and development records. Ignore rules do not remove previously tracked sensitive files. The publication checker includes such tracked files, but does not inspect commit history.

## Layout and documentation

```text
Sources/VirtualLocation/  SwiftUI interface, maps, and state model
backend/virtual_location/ Python device backend, sessions, and recovery
scripts/                  Setup, build, validation, and packaging
tests/                    Python offline and simulated tests
tests-swift/              Swift model and native map-click checks
assets/brand/             App logo and icons
docs/                     Usage, status reference, and publication review
```

Additional documentation is currently in Chinese:

- [Usage and validation](docs/使用与验证.md)
- [Status text and colors](docs/状态文案与颜色.md)
- [Developer images and Apple signing](docs/开发镜像说明.md)
- [Publication review](docs/开源发布检查.md)

When reporting an issue, include OS versions, reproduction steps, and redacted errors. Do not attach the whole `.state/` directory, pairing records, signing credentials, unique device identifiers, or private favorite locations.

## License and acknowledgments

This project is licensed under the **GNU General Public License, version 3 or any later version (GPL-3.0-or-later)**. See [LICENSE](LICENSE). Personal and commercial use, modification, and redistribution are permitted. Distributing original or modified versions requires compliance with the GPL, including corresponding source availability, license notices, and applicable same-license requirements. Private use or internal modification alone does not require public source publication. See the [GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#GPLCommercially).

- Device communication depends on `pymobiledevice3==11.49.0`, whose installed distribution declares **GPL-3.0-or-later**. The project's license does not replace dependency licenses.
- Coordinate-conversion equations are adapted from `wandergis/coordtransform`. Its MIT notice is reproduced in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- App artwork is generated by this project's vector drawing code. Map content is supplied by Apple and its data providers.

Before distributing bundled applications or installers, review the distribution requirements of all included dependencies and resources.
