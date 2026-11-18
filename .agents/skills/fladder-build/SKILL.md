---
name: fladder-build
description: >-
  Use this skill whenever building Fladder, running code generation or tests,
  resolving build/analyzer failures, or fetching and merging upstream changes
  in this repository.
---

# Fladder Build, Codegen & Upstream Merge Skill

Read [build.md](../../../build.md) for full build commands and architecture notes. Follow the guardrails below strictly when working in `c:\dev\Fladder`.

## Critical Guardrails

1. **Git Remotes**:
   - `origin` = **upstream** (`https://github.com/DonutWare/Fladder.git`, branch `develop`).
   - `fork` = **maintained fork** (`https://github.com/vicente-higino/Fladder.git`, branch `codex/personal-fixes` / `develop`).
   - Never push to `origin`.
2. **Windows Shell & SDK**:
   - Default shell is PowerShell 5.1 — do **not** chain commands with `&&` (use separate tool calls or `; if ($LASTEXITCODE -eq 0)`).
   - Check `.fvmrc` against `flutter --version` (`C:\dev\flutter\bin\flutter.bat`) before running `flutter pub get` after upstream merges.
   - `C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe analyze` is faster than `flutter analyze` and avoids `flutter.bat` lockfile contention.
3. **Code Generation (`build_runner` + `pigeon`)**:
   - **Never leave a `--build-filter` run as the final `build_runner` pass**: `build_runner 2.16+` deletes non-matching generated `.mapper.dart`, `.freezed.dart`, `.g.dart`, and `.chopper.dart` files. Always run a full `dart run build_runner build`.
   - Delete any `.freezed.dart` or `.g.dart` files containing `<<<<<<<` conflict markers before running `build_runner`.
   - `build_runner` does **not** run Pigeon. Whenever `pigeons/*.dart` changes or auto-merges with upstream, explicitly run:
     - `dart run pigeon --input pigeons/player_settings_pigeon.dart`
     - `dart run pigeon --input pigeons/video_player.dart`
4. **Flutter 3.50+ & Player Provider Rules**:
   - Use `import 'package:material_ui/material_ui.dart';` instead of `package:flutter/material.dart` in `lib/` and `test/`.
   - Do not eagerly read `videoPlayerProvider` from settings notifiers unless `ref.read(playBackModel)?.item != null` or `playerSame` changed — instantiating `videoPlayerProvider` in `flutter test` triggers `MediaKit.ensureInitialized()` and throws `Cannot find libmpv-2.dll`.
5. **Verification & Windows Build**:
   - Exclude `test/widget_test.dart` (unimplemented Flutter counter template) when running tests; run the feature test files listed in [build.md](../../../build.md).
   - Keep the `local_auth_windows_plugin` `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` block in `windows/CMakeLists.txt` (required for Visual Studio Build Tools 2026 / MSVC 14.51+).
