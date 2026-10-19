# Coastty

A terminal that keeps an eye on your agents.

Coastty is a terminal emulator for macOS, built on [Ghostty](https://ghostty.org), that lets you see which of your AI coding agents are working and which are waiting for you. It is free and open source.

A sidebar shows what every agent you are running is doing, in every tab, so you only look at a tab when something there needs you. Spaces keep your tabs organised, and your sessions outlive the app: quit Coastty, reopen it, and every shell and agent is still running where you left it. Layout commands let you, your scripts and your agents arrange it all from any shell.

Rendering, terminal emulation, the configuration format and Ghostty's keybindings all come from Ghostty, so its documentation applies.

## What it adds

### An agent sidebar

The sidebar lists every running agent with its attention state: Working, Blocked on a permission prompt, Done but not yet seen, or Idle. Blocked and Done agents sort to the top, and <kbd>⌘U</kbd> jumps to the agent that most needs you.

Coastty detects agents by reading their screen and title, using detection ported from [herdr](https://github.com/herdrdev/herdr), so the agent needs no plugin or hook to show up. Claude Code is the only agent it detects so far; the detection is set up for more.

### Spaces

A Space is a group of tabs. Jump between Spaces with <kbd>⌃⇧1</kbd> to <kbd>⌃⇧9</kbd>, or click one in the sidebar, and drag them into the order you want. Each Space shows the state of its most urgent agent, so you can tell which one needs you.

### Sessions that outlive the app

Every Space, tab and pane runs in `coastty-host`, a small daemon bundled with the app. Because the daemon owns the processes, quitting Coastty does not end them. Reopen the app and every terminal picks up where it left off, with its screen and scrollback.

Restarting or shutting down your Mac ends the processes that were running. Your Spaces and tabs come back, and each shell starts again in the directory it was in.

### Commands for people, scripts and agents

`coastty space`, `coastty tab` and `coastty pane` create, close, rename, reorder and focus Spaces and tabs, and split, close and focus panes, from any shell. `coastty space list`, `tab list`, `pane list`, `window list` and `focused` show what exists, with `--json` for scripts. An agent can tidy the tabs it works in; a script can lay out a piece of work.

`coastty skill` prints a skill file that teaches an agent the commands, and `coastty skill install` puts it where Claude Code finds it.

The commands change layout and nothing else. No command can type into a pane, start a program in one, or read what it shows, so letting an agent use them gives it nothing it did not already have. [ADR 0002](docs/adr/0002-layout-commands-never-type-or-read.md) records why.

## Install

Coastty runs on macOS Golden Gate. Install it with Homebrew:

```sh
brew install --cask ehs5/coastty/coastty
```

Homebrew also puts the `coastty` command on your `PATH`, and `brew upgrade` keeps Coastty up to date. To install by hand instead, download `Coastty.dmg` from [GitHub Releases](https://github.com/ehs5/coastty/releases) and drag Coastty into Applications.

### The first launch

Coastty is not yet signed with an Apple Developer ID, so macOS blocks it the first time you open it. Homebrew quarantines what it downloads just as a browser does, so this applies to both ways of installing.

1. Open Coastty. macOS says it could not verify that Coastty is free of malware. Choose **Done**.
2. Open **System Settings > Privacy & Security** and scroll down to **Security**. Next to the message that Coastty was blocked, click **Open Anyway**.
3. Confirm with your password or Touch ID, then choose **Open**.

Or clear the quarantine flag from a terminal, which skips all three steps:

```sh
xattr -dr com.apple.quarantine /Applications/Coastty.app
```

macOS asks again after each `brew upgrade`. Every build carries a new ad-hoc signature, so Homebrew cannot carry your approval over to the new version, and says so with a "signer changed" warning.

### Building from source

You need [Zig 0.16](https://ziglang.org/download/) and a recent Xcode.

```sh
zig build -Doptimize=ReleaseFast
cp -R zig-out/Coastty.app /Applications/
```

`zig build test` runs the test suite. [HACKING.md](HACKING.md) has more on developing, much of it inherited from Ghostty.

Coastty is macOS only. Ghostty's Linux (GTK) app, its experimental iOS/browser targets, and its Linux and Windows packaging are still in the repo, but are not maintained or supported here. They have been kept to more easily merge in improvements from Ghostty. And who knows, maybe we would like the Linux/other targets later.

### The `coastty` command

Inside Coastty's own panes, `coastty` is already on your `PATH`, and a Homebrew install puts it there for every terminal. Without Homebrew, choose **Coastty > Install 'coastty' command in PATH**. It links `/usr/local/bin/coastty` to the app and asks for your password only if that folder needs it. **Uninstall 'coastty' command from PATH** removes the link again.

## Configuration

Coastty uses Ghostty's configuration format, so [Ghostty's documentation](https://ghostty.org/docs/config) applies. Coastty reads its own file at `~/.config/coastty/config.coastty` and never touches a Ghostty installation's configuration.

Coastty opens in its own `Coastty` theme, drawn from the colours of the app icon, with `Coastty Light` alongside it; `theme = light:Coastty Light,dark:Coastty` follows the system appearance. Every Ghostty theme works too, and the sidebar takes its colours from the one you choose.

## How it fits together

The daemon is the source of truth for the model, and the app is one client of it. [CONTEXT.md](CONTEXT.md) defines the terms, and the decisions that are hard to reverse are in [docs/adr/](docs/adr/).

`coastty-host` has a small command line for looking inside a running daemon:

```sh
coastty-host model    # Spaces, tabs, panes and agent status, as JSON
coastty-host events   # what changes, as it happens
```

## Contributing

Issues and pull requests are welcome. Open an issue and agree on the approach first; [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## Credits

Coastty is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and its contributors. Nearly all of the code is theirs.

Agent detection is ported from [herdr](https://github.com/herdrdev/herdr) (Apache 2.0).

Made by [Espen Steen](https://steen.cc).

## Licence

MIT. [LICENSE](LICENSE) keeps Ghostty's copyright notice. The agent-detection code in `src/agent-detection/` is derived from herdr and is licensed under the Apache License 2.0; see [`src/agent-detection/LICENSE-herdr`](src/agent-detection/LICENSE-herdr).
