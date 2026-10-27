# Rail presentation playground

Run `./presentation/run.sh` from the Cockpit checkout. This opens **Cockpit Rail
· Presentation**, a separate rail-only window with no agent sockets or embedded
terminal.

- Edit `presentation/rail/Rail.qml` for layout and typography. Quickshell
  reloads the preview live.
- Edit `presentation/shell.qml` for the samples and preview controls.
- Use **Conversation**, **Markdown**, **Subagents**, and **Approval** to
  reproduce different states. **Replay** resets the selected sample; **Stream**
  adds a growing response.
- Resize the window to check narrow/wide layouts. The normal rail mouse and
  keyboard interactions are retained.
- **Approval** uses a dedicated question card in the chat. Approve/Decline
  replaces the buttons with an attached **Your answer** section, not a separate
  user message. The card height animates over 260 ms; actions and answer content
  crossfade over 200 ms.
- **While typing** opens the composer, then introduces a question after one
  second. Your draft keeps focus. Enter sends chat, not a question answer;
  Escape does not activate the question. Answer via its buttons, or explicitly
  select and activate its chat row before using answer shortcuts.
- Composer messages and approvals are local mock events. File-open,
  session-create, lifecycle, and plan-binding actions are disabled.

`presentation/rail/` is an editable snapshot of the production rail and its
three dependencies, not a symlink. Editing it does not change either running
Cockpit. Production fixes must be deliberately ported back to `qs-shell/`; this
playground does not sync changes automatically.

The launcher reuses the existing `build/qml` plugin and QsLib; no native build
is performed. Its home and runtime state are isolated under
`~/.local/state/cockpit/rail-presentation/`.

Validate the actual app with `./presentation/run.sh --check`. This loads all
samples offscreen, clicks both approval actions, samples intermediate height and
crossfade frames, checks attached answers and typing safety, completes streaming
without duplication, and captures the answered card without connecting to an
agent daemon.
