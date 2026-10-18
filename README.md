# coastty

A macOS terminal for working with coding agents, built on [Ghostty](https://ghostty.org).

coastty is Ghostty with two additions. A sidebar shows what every agent you are running is doing, in every Space, so you only look at a tab when something there needs you. And your sessions outlive the app: quit coastty, reopen it, and every shell and agent is still running where you left it.

Everything else is Ghostty. The rendering, the terminal emulation, the configuration and the keybindings all come from it unchanged.

## What it adds

### An agent sidebar

The sidebar groups your tabs into Spaces and lists every running agent beneath them, with its attention state: working, blocked on a prompt, done but not yet seen, or idle. When an agent in a tab you are not looking at finishes or asks for permission, the sidebar is where you see it.

coastty detects agents by reading their screen and title, the way [herdr](https://github.com/herdrdev/herdr) does, so the agent needs no plugin or hook to show up. Claude Code is the only agent it recognises so far.

### Sessions that outlive the app

Every pane runs in `coastty-host`, a small daemon bundled with the app. Because the daemon owns the processes, quitting or crashing coastty does not end them. Reopen the app and each pane reattaches to its own process, with its screen and scrollback.

The daemon also keeps the structure: your Spaces, their tabs and the panes in each tab. If you restart your Mac, the Spaces and tabs come back and each shell starts again in the directory it was in. The processes themselves do not survive a restart.

## Status

coastty is early and runs on macOS only. There are no release builds yet, so you build it from source, and it does not update itself.

Reaching your panes from another device is in progress. The daemon already shares the model and agent status with any client that connects.

## Building

You need [Zig 0.16](https://ziglang.org/download/) and a recent Xcode. coastty is developed and tested on macOS 27 Golden Gate. It ran on macOS 26 earlier, but that has not been checked since; older versions have not been tried.

```sh
zig build -Doptimize=ReleaseFast
```

The app is built to `zig-out/Coastty.app`. Copy it to `/Applications` to install it.

`zig build test` runs the test suite. [HACKING.md](HACKING.md) has more on developing, much of it inherited from Ghostty.

### Commands for people, scripts and agents

`coastty space`, `coastty tab` and `coastty pane` create, close, rename and reorder Spaces and tabs, and split and close panes, from any shell. An agent can tidy the workspace it works in; a script can lay out a project. `coastty skill` prints a skill file that teaches an agent the commands, and `coastty skill install` puts it where Claude Code finds it.

They change layout only. Nothing can type into a pane, start a program in one, or read what it shows, so letting an agent use them gives it nothing it did not already have. [ADR 0002](docs/adr/0002-layout-commands-never-type-or-read.md) records why.

## The `coastty` command

Inside coastty's own panes, `coastty` is already on your `PATH`. To use it from other terminals, choose **Coastty > Install 'coastty' command in PATH**. It links `/usr/local/bin/coastty` to the app and asks for your password only if that folder needs it. **Uninstall 'coastty' command from PATH** removes the link again.

Once there are release builds, the Homebrew cask in `Casks/coastty.rb` does the same on install:

```sh
brew tap ehs5/coastty https://github.com/ehs5/coastty
brew install --cask coastty
```

On Intel Macs Homebrew links into `/usr/local/bin` too, so the cask and the menu items manage the same `/usr/local/bin/coastty`. Use one or the other: the uninstall menu item removes the link the cask created.

## Configuration

coastty uses Ghostty's configuration format, so [Ghostty's documentation](https://ghostty.org/docs/config) applies. coastty reads its own file at `~/.config/coastty/config.coastty` and never touches a Ghostty installation's configuration.

coastty opens in its own `Coastty` theme, drawn from the colours of the app icon, with `Coastty Light` alongside it; `theme = light:Coastty Light,dark:Coastty` follows the system appearance. All of Ghostty's bundled themes are available too.

## How it fits together

The daemon is the source of truth for the model, and the app is one client of it. [CONTEXT.md](CONTEXT.md) defines the terms, and the decisions that are hard to reverse are in [docs/adr/](docs/adr/).

`coastty-host` has a small command line for looking inside a running daemon:

```sh
coastty-host model    # Spaces, tabs, panes and agent status, as JSON
coastty-host events   # what changes, as it happens
```

## Credits

coastty is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and its contributors. Nearly all of the code is theirs.

Agent detection is ported from [herdr](https://github.com/herdrdev/herdr) (Apache 2.0).

## Licence

MIT. [LICENSE](LICENSE) keeps Ghostty's copyright notice. The agent-detection code in `src/agent-detection/` is derived from herdr and is licensed under the Apache License 2.0; see [`src/agent-detection/LICENSE-herdr`](src/agent-detection/LICENSE-herdr).
