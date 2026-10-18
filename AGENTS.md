# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Contributing to coastty

Follow [CONTRIBUTING.md](CONTRIBUTING.md). For an agent, that comes down to:

- Never open an issue or pull request yourself. Prepare it; the person you work for reviews it and sends it.
- Before writing a change, check that there is an issue with the approach agreed. A pull request without one may be closed without notice.
- Report exactly what you built, ran and tested, and say plainly what you could not.
- Add an `Assisted-by:` line to your commits naming the tool and model.

## Agent skills

- **Issue tracker:** GitHub Issues in `ehs5/coastty`, through the `gh` CLI. See `docs/agents/issue-tracker.md`.
- **Triage labels:** the default five-role vocabulary, used as-is. See `docs/agents/triage-labels.md`.
- **Domain docs:** single context, `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.

cmux is GPL-licensed: use it as a reference only, and never copy code from it.

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`

## Not maintained for coastty

coastty is a macOS-only fork of Ghostty. The following, inherited from upstream
Ghostty, are not coastty's own implementation and get no attention here
beyond whatever keeps them compiling. Don't spend any time looking these folders unless explicitly told to do so.

- **GTK app (Linux/FreeBSD)**: `src/apprt/gtk/`, `src/apprt/gtk.zig`
- **Browser/WASM runtime**: `src/apprt/browser.zig`
- **iOS app**: the `Ghostty-iOS` Xcode target and `macos/Sources/App/iOS/`
  (most other files under `macos/Sources/` are shared with this target
  via `#if os(iOS)` branches — those branches aren't coastty's concern,
  the surrounding macOS code is)
- **Linux/Windows packaging**: `flatpak/`, `nix/`, `dist/linux/`,
  `dist/windows/`, `dist/cmake/`
