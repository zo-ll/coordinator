# coordinator

A harness-agnostic, script-driven, barebones multi-agent orchestration protocol.

**Status: design phase — no implementation yet. See [SPEC.md](SPEC.md).**

The protocol decomposes a goal into small vertical slices, runs one worker per
slice on an isolated git worktree, has an independent critic review each
survivor (producer-severed: the critic never sees the worker's framing), and
merges only after a review pass bound to an exact commit plus the user's
approval.

The coordinator itself is a thin dispatcher over a set of **bash** scripts.
Finished work is always a file; a worker enqueues a ping into an ordered queue,
and a single relay consumes the queue and resumes the coordinator's session.
It runs on any single installed harness (Codex, Claude, pi, …) with **no
`tmux`, no `python`, and no `node` required**.

This repository was split out of [zo-ll/skills](https://github.com/zo-ll/skills)
so the flow can evolve on its own. The earlier implementation still exists in
that repository's history.
