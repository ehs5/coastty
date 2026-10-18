# ADR-0002: Layout commands change layout only; they never type into a pane or read one

Status: accepted, 2026-10-12.

## Context

herdr, the closest tool to coastty, gives agents a command line that creates
panes, sends prompts and keystrokes to them, and reads their screens. People
running multi-agent setups use it daily. The same people report agents
hijacking the prompt they were typing in, and injected prompts showing up in
Claude Code as if a human had typed them. Nobody outside that group seems to
use it at all.

Typing into or reading a pane reaches things an agent has no other way to
reach: an SSH session, a `sudo` prompt waiting for a password, a token on
screen, another agent's output. A read is invisible to the tool permissions
the user set up for the agent. Starting a command in a new pane has the same
problem in a quieter form: `coastty tab new -- sudo ...` matches no rule that
denies `sudo`, and the password prompt it opens is answered by the user, not
the agent. Agents can already run any command; the only thing these would add
is a way around whatever the user blocked.

## Decision

The `coastty space`, `coastty tab` and `coastty pane` commands create, close,
rename and reorder Spaces and tabs, and split and close panes. That is all. A
new tab or split opens the user's default shell with nothing typed into it.
There is no command that sends input to a pane, starts a program in one, or
returns what a pane shows.

This is a promise to the user, not a gap: allowing an agent to use coastty's
commands cannot give it anything it did not already have.

## Consequences

- The commands are modest. An agent can tidy the workspace it works in and a
  script can lay out a project; neither can use a pane it opened. Accepted.
- Orchestration of the herdr kind (one agent prompting another through its
  pane) is out of scope for coastty, not merely not built yet.
- Any future read or write command needs its own decision, and would need the
  user in the loop for each access, not a flag an agent can pass.
- Rejected: starting a command in a new pane; reading the last lines of a
  pane; sending keystrokes.
- The daemon enforces the promise at its socket, for every client and not
  just the command line: `ATTACH`, `CREATE` and `KILL` (and `SWEEP`, which
  also ends panes) need a token the daemon writes owner-only beside the
  socket and only the app sends, and never places in a pane's environment.
  Same-user isolation on macOS is not airtight - a determined process can
  read the file too - but nothing reaches into a pane by accident or with a
  few lines of script.
