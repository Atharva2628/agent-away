# Agent Away

A menu-bar switch for leaving Claude Code agents (desktop Code tab and CLI) working
while you're away: lid closed, laptop in a bag, Wi-Fi coming and going.

The icon shows only while Claude (app or CLI) or the grok CLI is running.

## Requirements
- macOS 15 or later (uses the built-in `/usr/bin/jq`), Apple Silicon recommended
  (per-process GPU measurement uses the Apple GPU driver's accounting).
- Xcode Command Line Tools (`xcode-select --install`) to compile; no Xcode, no dependencies.
- Claude Code (desktop app Code tab or CLI). The grok CLI is supported through the same hooks.

| Icon | Meaning |
|---|---|
| moon | Mac sleeps normally (default) |
| sun | Keep awake is on |
| question bubble | Only "ask first, then don't" is on |
| flame | Heat guard is throttling or pausing something |
| wifi ! | Keep awake is on and the network is down |

## The two switches

**Keep awake, even with lid closed**
- Lid open: blocks idle system sleep. The display still sleeps and the screen still locks;
  agents keep running behind the lock.
- Lid closed: sets `pmset disablesleep 1` (needs the one-time sudo rule, see Setup).
- Heat guard (lid closed only), in layers:
  1. Agents are told up front to avoid heavy CPU/GPU work: rendering/encoding, media batch
     jobs, ML training or local inference, simulators, VMs, image builds, benchmarks, long
     loops, huge builds/test runs.
  2. Commands that are heavy by nature are refused (matched as commands, not words in a
     message): ffmpeg, HandBrakeCLI, blender, remotion render, manim, torchrun, deepspeed,
     `python train*.py`, mlx_lm, whisper, ollama run, llama.cpp, stress/benchmarks/miners,
     qemu, docker/podman image builds, simulator boots, and more. Normal builds and tests run.
  3. Whatever the command, everything an agent launched is measured for CPU **and GPU**
     every 10 s, including short-lived build workers and `nohup`/`&` jobs that detached.
     Over the limit (150% CPU or 40% GPU for 60 s; half that for 30 s once the Mac is warm;
     anything busy once it's hot) it moves to background priority: efficiency cores, about
     98% less power, still finishes. A Bash job is paused if the GPU stays over the limit
     (background priority doesn't slow the GPU) or the Mac stays hot, and resumed (still
     slowed) once the Mac has cooled down for 3 min. MCP and language servers are only
     ever slowed, never paused.
  4. Heavy apps you own that aren't agent children (an app an agent opened, a Docker VM)
     get background priority too, never paused.
  5. Critical heat, or hot for 5 min: keep-awake turns off and the Mac goes to sleep (when
     no external display is in use). Paused jobs stay paused until the lid opens.

**What it will never do to a process:** terminate it. No SIGTERM/SIGKILL anywhere. It only
changes priority and pauses/resumes, and everything is undone when the lid opens, the mode
turns off, or the app quits or crashes (it resumes them on relaunch). It never touches
anything signed by Apple (macOS, Apple apps, system tools), anything outside `/Applications`,
`~/Applications`, `/opt/homebrew`, `/usr/local` or your home folder (unless an agent launched
it), the Claude app, or the agents themselves. Before each action it re-checks the pid's
start time and owner, so a recycled pid can't redirect it. Root-owned system processes are
off limits to it anyway.

**Ask first, then don't**
- Busy sessions get told at their next step to ask you every question they foresee, in one
  message as a numbered list, each with a recommended default (in plain text: the question
  dialog can't time out). Idle sessions get this with your next message. Subagents and
  headless `claude -p` scripts are left out.
- After you answer, `AskUserQuestion` is refused and a reply that ends on a question is
  sent back with "decide yourself, note the assumption, keep going".
- If you leave without answering, after 10 min (configurable) the session is woken and told
  to go with its own defaults.
- For Claude Chat (no hooks there), "Copy 'ask me first' prompt" puts the same instruction
  on the clipboard.

## Automatic off (back to normal)
- Claude app and every Claude Code / grok CLI session quit.
- Every session finished and no Bash job they started is using CPU for 15 min
  (configurable). Not while a session waits for the network to come back or for your
  answers.
- Battery at or below 20% (configurable) while unplugged.
- Critical heat, or "serious" heat for 5 min, with the lid closed.
- The app quits, crashes (it restarts and resets), or the Mac restarts.

With the lid closed, switching off also puts the Mac to sleep, since the lid-close already
happened. If lid-closed mode was already on before Agent Away (your own setting), it is
used but never turned off.

## Flaky network
- A turn that ended on an API or network error (overloaded, server error, cut-off output,
  unknown, which covers dropped connections) is woken with "please continue" once
  api.anthropic.com is reachable again (checked every 15 s for up to 2 h). At most 3 times
  per session per hour, only while Keep awake is on. Rate limits and auth errors are left
  alone. Claude Code's own stream watchdog turns most dead connections into such an error
  within a few minutes.
- A session that has been waiting on the API with no progress for 20 min (configurable),
  and has received no network data at all for 20 s, gets a "please continue" through
  Claude Code's own per-session message socket. That aborts the stuck request like Esc
  and starts a fresh turn. Never while a tool is running, in plan mode, or more than 3
  times an hour, and never for a long reply that is still streaming. Works for desktop
  and CLI sessions, with the screen locked.

## Setup

```bash
sh scripts/install.sh
```
Builds the app (about 450 KB) into `~/Library/Application Support/AgentAway`, outside the
iCloud-synced Desktop. Adds hooks to `~/.claude/settings.json` next to the existing ones,
after backing the file up. Adds a login item.

For lid-closed mode, once (asks for your password):
```bash
sh scripts/setup-sudo.sh
```
It allows exactly `pmset -a disablesleep 0` and `... 1` without a password, nothing else.

Command line (optional), handed to the running copy:
```bash
"$HOME/Library/Application Support/AgentAway/AgentAway.app/Contents/MacOS/AgentAway" --away --ask-first
```
(`--off` switches both back off.)

## Remove

```bash
sh scripts/uninstall.sh
```
```bash
sh scripts/setup-sudo.sh --remove
```

## Cost
- Idle (no agents running): no timers, no polling. Wakes only on OS notifications.
- A mode on: one 60 s check. Lid closed and away: a 10 s process sample, about 1 ms each.
- Hooks: about 4 ms per event when no mode is on, about 20 ms when one is.
- Disk: source about 60 KB, built app about 450 KB, runtime state a few bytes.
- Memory: about 13 MB.
