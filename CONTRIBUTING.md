# Contributing to coastty

Issues and pull requests are welcome, and so is code written with AI. coastty itself is built that way. What matters is that a person stands behind every contribution.

## Before you start

- Open an issue first and agree on the approach before you write the change. Any pull request without an agreed issue may be closed without notice.
- Rendering, terminal emulation and configuration are Ghostty's. Changes there belong [upstream](https://github.com/ghostty-org/ghostty).

## Working with AI

- You are the author. Read what your tools produced, run it, and be ready to explain it in review.
- A contribution should be worth more than the time it takes to review. Unreviewed AI output rarely is.
- Say which tools you used, with an `Assisted-by:` line in your commits, for example `Assisted-by: Claude Code (Claude Opus 5)`.
- Say what you could not do. If something was not built, tested or reproduced, write that in the pull request.
- Agents do not open issues or pull requests on their own. A person reviews them and sends them.

## Making the change

- Put logic in Zig, not Swift. The Zig core and the daemon are shared by every client, and the Mac app should only display what they tell it.
- Use the terms in [CONTEXT.md](CONTEXT.md) for Spaces, tabs, panes and agent state.
- Run `zig build test` before you open a pull request.
