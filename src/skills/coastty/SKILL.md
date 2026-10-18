---
name: coastty
description: "Organise coastty's Spaces, tabs and panes from the command line with `coastty space`, `coastty tab` and `coastty pane`: open a tab or split for a build or a second shell, give a task its own Space, rename, reorder and close what you made. Use when running inside coastty (COASTTY_PANE_ID is set) and the user asks for layout to change, or a task needs a shell of its own beside yours. These commands only change layout: they never type into a pane or read one."
---

# coastty layout commands

coastty is a macOS terminal with a sidebar of **Spaces**. A Space holds **tabs**, a tab holds one or more **panes** (splits), and every pane runs a shell. The `coastty` binary on `PATH` in every pane has **layout commands** that create, close, rename and reorder Spaces and tabs, split and close panes, and bring any of them to the front.

Layout commands change layout and nothing else. They never type into a pane, send it keys, or read its screen or scrollback. A new tab or split always starts the user's own shell, with their config, in a directory you choose; you can't start it with a command. Nothing you create takes focus unless you pass `--focus`, so the user's typing is never interrupted.

## Check that you run inside coastty

```bash
test -n "${COASTTY_PANE_ID:-}"
```

coastty sets `COASTTY_PANE_ID` to the id of the pane you run in. Commands use it to act on your own pane, tab and Space when you give no id, even when the user is looking at another Space. Outside coastty the commands still work: `tab new` goes to the focused Space, `pane split` splits the focused pane, `space new` uses the frontmost coastty window, and close, rename and move need an explicit id, so nothing is closed or changed just because it happens to be on screen.

## Ids

Ids are opaque: Space and tab ids are UUIDs, pane ids look like `surface:<UUID>`. Read them from a command's output or a list; never guess them or copy them from examples. An id never comes back once what it named is closed.

## Find your way around

```bash
coastty space list [--json]
coastty tab list [--space <space-id> | --all] [--json]
coastty pane list [<tab-id>] [--json]
coastty window list [--json]
coastty focused [--json]
```

- `space list` shows every Space, hidden ones included: id, name, tab count, whether it is hidden, and the id of the window showing it.
- `tab list` shows the tabs of your Space, of `--space`, or of every Space with `--all`: id, name, pane count and 1-based position. The name is the user's, else the title of the tab's first pane, as the tab bar shows it. `--all` adds which Space each tab is in. Outside coastty, with neither, it lists the focused Space.
- `pane list` shows the panes of your tab, or of the tab named. Outside coastty, with no tab named, it lists the focused tab.
- `window list` shows every coastty window: its id, the Space it is showing (`ACTIVE`, or `active` in `--json`) and every Space it shows, in order. Window ids are UUIDs and stay the same when the app is quit and opened again.
- Every list marks your own Space, tab or pane with `*` and the focused one, which the user was last in, with `>`. In `--json` these are the `caller` and `focused` fields.
- `focused` prints the focused Space, tab and pane, one row each with its id and the name the sidebar shows: the active Space, tab and pane of the coastty window the user was last in. It stays while coastty is in the background, so it works from another terminal, and goes when that window closes. With `--json` it prints `space` and `tab` as `{id, name}` and `pane` as `{id, title, directory}`. It fails with `coastty has no focused window` when every coastty window is closed.
- `--json` prints the same rows as a JSON array. Use it whenever you parse the output.

Lists read coastty-host's model, so they work while the app is closed, as long as the daemon runs. Windows are known only while the app runs: with it closed, `window list` is empty and `space list` shows no windows.

## Tabs

```bash
coastty tab new [--name <name>] [--cwd <dir>] [--space <space-id>] [--focus]
coastty tab close [<tab-id>] [--force]
coastty tab rename [<tab-id>] <name>
coastty tab move [<tab-id>] <position>
```

- `tab new` adds a tab at the end of your Space, or of `--space`. It starts in your current directory; `--cwd` picks another, relative to where you run the command. Outside coastty it goes to the focused Space unless given `--space`, and starts in the home folder unless given `--cwd`. It prints only the new tab's id, so `tab=$(coastty tab new --name build)` captures it.
- `tab close` closes your tab or the one named, ending everything in its panes. Closing a Space's last tab closes the Space, and the last Space closes its window.
- `tab rename` sets the tab's name. An empty name (`""`) clears it, and the default comes back.
- `tab move` moves the tab to a 1-based position within its own Space. A position past the last tab is refused.

## Spaces

```bash
coastty space new [--name <name>] [--cwd <dir>] [--window <window-id>] [--focus]
coastty space close [<space-id>] [--force]
coastty space rename [<space-id>] <name>
coastty space move [<space-id>] <position>
coastty space move [<space-id>] --window <window-id> [<position>]
```

- `space new` makes a Space with one starter tab, in the window `--window` names, else the window showing your own Space (outside coastty, the frontmost window). `--name` and `--cwd` work as for `tab new`. It prints the Space's id and the starter tab's id on one line: `read space tab < <(coastty space new --name review)`.
- `space close` closes your Space or the one named, with every tab in it.
- `space rename` works like `tab rename`.
- `space move` moves the Space to a 1-based position among the visible Spaces, the same numbering as the sidebar and the ⌃⇧1-5 shortcuts. Hidden Spaces don't count, and a hidden Space can't be moved.
- `space move --window` moves the Space to another window, after that window's last visible Space or at a 1-based position among them. It prints `moved space <id> to window <window-id> at <position>`. A window that is left with no Space closes; nothing in the Space is ended.
- There is no command to open or close a window. A window exists while it shows a Space, and closing its last Space closes it.

## Panes

```bash
coastty pane split [<pane-id>] --direction right|down [--cwd <dir>] [--focus]
coastty pane close [<pane-id>] [--force]
```

- `pane split` splits your pane, or the one named, and starts a shell beside it in your current directory or `--cwd`. Outside coastty it splits the focused pane unless given an id. `--direction` is required. Split a wide pane `right` and a tall or narrow one `down`, and avoid splitting the same way again and again until the panes are too small to use. It prints only the new pane's id.
- `pane close` closes your pane or the one named. Closing a tab's last pane closes the tab.

## Taking the user somewhere

```bash
coastty space focus [<space-id>]
coastty tab focus [<tab-id>]
coastty pane focus [<pane-id>]
```

- `space focus` shows the Space in its window and brings that window to the front. `tab focus` also selects the tab, and `pane focus` also moves keyboard focus to the pane.
- With no id they take the user to your own Space, tab or pane. Outside coastty they need an id.
- Each prints one line, such as `focused tab <id>`, once coastty reports the user is there.
- These take the user's focus away from whatever they are doing. Use them only when the user asked to be taken somewhere, or when you are done and need them to look.

## Closing is refused while something runs

A close is refused while anything other than a shell at its prompt runs in what it would close, and the refusal names what runs:

```text
$ coastty tab close 5F2A...
running npm, vim
```

Nothing is closed. Pass `--force` only when ending those processes is right: you started them, or the user asked. A forced close says what it ended: `closed tab 5F2A... (ended npm, vim)`.

The command doing the closing doesn't count, so a person can run `coastty tab close` at their own prompt. You are a running process too: to close the tab or pane you run in yourself, you need `--force`, and it ends you.

## Output, waiting and exit codes

- `new` and `split` print ids on stdout and nothing else. `close`, `rename`, `move` and `focus` print one short line, such as `closed tab <id>`, `renamed space <id> to "review"`, `moved tab <id> to 2` or `focused pane <id>`.
- Every command waits until coastty shows the change before it returns, so the next command sees it. You never need to sleep or poll after one.
- Errors go to stderr. Exit code 0 is success, 1 a failure, 2 a usage mistake (a bad option, a missing argument, or no id given outside coastty).

Failures you may see, all exit 1:

| Message | Meaning |
| --- | --- |
| `coastty isn't running` | The app is closed, or the daemon is not running. Lists need only the daemon. |
| `running <names>` | A close was refused, see above. |
| `no such space`, `no such tab`, `no such pane` | The id names nothing, or was already closed. With no id given, `no such pane` means coastty doesn't know the pane you run in. |
| `no such window` | `--window` names no open coastty window. Read window ids from `coastty window list`. |
| `no such position` | A move past the last tab or visible Space. |
| `coastty has no focused window` | Outside coastty, `tab new` without `--space`, `pane split` without an id, or `focused` found no coastty window to use: every window is closed. |
| `space is hidden` | A hidden Space has no position to move to. |
| `command attempted, but could not verify that coastty applied the change` | coastty accepted the command but didn't show the change within about 3 seconds. Check with a list before you try again; it may have happened. |

## Working alongside the user

- Don't close Spaces, tabs or panes you didn't create unless the user asked.
- Leave focus alone. Use `--focus` or a `focus` command only when the user asked to be taken somewhere, or when you are done and need them.
- Prefer a split or a tab in your own Space. Make a new Space only for separate work, or when asked.
- Name what you create, so the sidebar says what it is for.

## Install

`coastty skill` prints this file. `coastty skill install` copies it to `~/.claude/skills/coastty/SKILL.md`, replacing an older copy.

The shape of this skill follows herdr's `skills/herdr/SKILL.md` (https://github.com/herdrdev/herdr, Apache-2.0): checking the pane environment first, reading ids from output, choosing a split direction by the pane's shape, and leaving alone what you didn't create. The text is coastty's own.
