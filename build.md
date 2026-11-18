# Building & Maintaining Fladder (Fork Guide for Agents)

This repository is a maintained fork of [DonutWare/Fladder](https://github.com/DonutWare/Fladder) with custom playback, subtitle, connectivity, and Windows stability fixes.

## 1. Repository & Remote Layout

- **`origin`** (`https://github.com/DonutWare/Fladder.git`): **Upstream** repository (`origin/develop`). Never push here.
- **`fork`** (`https://github.com/vicente-higino/Fladder.git`): **Maintained fork** (`codex/personal-fixes` / `develop`).

### Custom Fork Capabilities to Preserve on Upstream Merges
- **Playback speed persistence**: `rememberPlaybackRate`, `defaultPlaybackRate`, `lastPlaybackRate` (`VideoPlayerSettingsModel`, `VideoPlayerSettingsProviderNotifier`, `pigeons/player_settings_pigeon.dart`, `pigeons/video_player.dart`, and `lib/l10n/app_*.arb` keys `rememberPlaybackRateTitle`, `rememberPlaybackRateDesc`, `defaultPlaybackRateTitle`, `defaultPlaybackRateDesc`).
- **Delayed media segment live refresh**: `MediaSegmentRefreshController` in `lib/models/playback/media_segment_refresh_controller.dart` and `VideoPlayerNotifier`.
- **Regional subtitle selection & `Always` mode**: `lib/util/streams_selection.dart`, `lib/util/jellyfin_extension.dart`, and `lib/models/playback/*`.
- **Server outage auto-recovery**: `ConnectivitySnapshot` + exponential retry backoff in `lib/providers/connectivity_provider.dart` alongside upstream's `offlineStateProvider` and `waitForProbe()`.
- **Windows startup & resize stability**: Deferred player initialization (`video_player_provider.dart`), deferred window placement restoration (`lib/util/window_helper.dart`, `desktop_platform_wrapper.dart`), and native `WM_SIZE` handling (`windows/runner/flutter_window.cpp`, `win32_window.cpp`).

---

## 2. Environment Requirements (Windows)

- **Flutter SDK**: Match the version pinned in [`.fvmrc`](.fvmrc) (currently Flutter `3.50.0` / Dart `3.14.0`, installed at `C:\dev\flutter`).
  - If upstream bumps `.fvmrc` or `pubspec.lock` SDK constraints, upgrade Flutter first (`flutter upgrade`).
- **Visual Studio Build Tools**: Visual Studio Build Tools 2026 (MSVC `14.51+`) with Desktop development with C++.
- **Shell note**: Windows PowerShell 5.1 does not support `&&`. Run commands separately or use `; if ($LASTEXITCODE -eq 0) { ... }`.

---

## 3. Step-by-Step Build & Codegen Workflow

### Step 1: Install Dependencies & Generate Localizations
```powershell
flutter pub get
```
`flutter pub get` resolves `pub.dev` and `DonutWare/media-kit` git overrides and automatically generates `lib/l10n/generated` from `lib/l10n/app_*.arb`.

### Step 2: Regenerate Pigeon Bindings (When `pigeons/*.dart` Changes or Merges)
`build_runner` does **not** run Pigeon. If `pigeons/*.dart` was edited or auto-merged with upstream, regenerate explicitly:
```powershell
C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe run pigeon --input pigeons/player_settings_pigeon.dart
C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe run pigeon --input pigeons/video_player.dart
```

### Step 3: Run Full `build_runner` Code Generation
Generates Freezed, JsonSerializable, Riverpod, DartMappable, Drift, Chopper, and AutoRoute files:
```powershell
C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe run build_runner build
```
> **IMPORTANT**:
> - Do **not** use `--build-filter` as your final step — `build_runner 2.16+` deletes all generated `.mapper.dart`, `.freezed.dart`, `.g.dart`, and `.chopper.dart` files outside the filter.
> - If a generated `.freezed.dart` or `.g.dart` file has git conflict markers (`<<<<<<<`), delete that generated file before running `build_runner build`.

### Step 4: Static Analysis
```powershell
C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe analyze
```
- Flutter 3.50+ uses `import 'package:material_ui/material_ui.dart';` instead of `package:flutter/material.dart`.

### Step 5: Automated Unit Tests
Run all feature test suites explicitly (`test/widget_test.dart` is an unused Flutter counter template without a `ProviderScope` and will fail if included):
```powershell
flutter test `
  test/connectivity_provider_test.dart `
  test/local_url_persistence_test.dart `
  test/media_segment_refresh_controller_test.dart `
  test/pip_manager_test.dart `
  test/playback_rate_settings_test.dart `
  test/single_flight_initializer_test.dart `
  test/streams_selection_test.dart `
  test/video_player_initialization_test.dart `
  test/window_helper_test.dart
```
> **Note on `libmpv-2.dll` in tests**: Unit tests run without `libmpv-2.dll` on `%PATH%`. Settings providers must not instantiate or call `videoPlayerProvider` unless `playBackModel` has an active item or `playerSame` changed.

### Step 6: Build Windows x64 Release
```powershell
flutter build windows --release
```
- **Output**: `build\windows\x64\runner\Release\fladder.exe` (distribute the entire `Release\` directory as a portable `.zip`, as it contains required DLLs and `data\`).
- **MSVC 14.51+ (`local_auth_windows`)**: [`windows/CMakeLists.txt`](windows/CMakeLists.txt) defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` on `local_auth_windows_plugin` right after `include(flutter/generated_plugins.cmake)` to prevent `error C2338: STL1011`. Keep this block intact on merges.
- **Benign Cargokit message**: `smtc_windows` prints `Get-Item : Could not find item C:\Users\...\AppData` from `resolve_symlinks.ps1` during build; this is non-fatal.
