# Finish protocol (workers and reviewers ping the coordinator)

Unified and harness-agnostic: every completed turn — from pi, Claude Code,
Codex, or any future harness — uses the SAME ping channel (the inbox relay)
and the SAME local recovery marker. Two artifacts per finish; write the
marker before publishing its ping.

## 1. Ping — write ONE line to the inbox (ALL harnesses)

The ping line is the coordinator's wake-up AND its evidence: carry result and
summary in it so no marker read is needed to route.

    pending=$(mktemp /tmp/shipwright/inbox/.publish.XXXXXX)
    printf 'DONE <task>: <result> — <one-line summary>\n' > "$pending"   # worker
    printf 'VERDICT <task>: <pass|handback> @ <full-reviewed-commit> — <one-line summary>\n' > "$pending"   # critic
    mv -- "$pending" /tmp/shipwright/inbox/<task>.ping

- Event identity is the filename minus its final `.ping`: task + round +
  role. A first worker completion may use `<task>.ping`; its critic uses
  `<task>.critic.ping`. A new round uses `<task>.r2.ping` for the worker and
  `<task>.r2.critic.ping` for the critic. Keep these components consistent
  within an assignment; the relay compares the entire slug literally.
- A retry of ONE event MUST reuse its filename, even if its wording changes.
  A genuinely new round MUST use a new round filename. Checkpoint/correction
  events also need their own distinct event slug if separately delivered.
- ONE line only — never multi-line content.
- PING ONCE: the relay dedupes by event slug with fixed-string whole-line
  matching. Rewrites of a delivered event log `DUP` regardless of content;
  a different role or round still delivers, even with identical content.
  Dedupe memory lasts for the relay process lifetime and resets on restart.
  Do not re-publish completed events after restarting the relay.
- Publish atomically: write the complete line to a temporary file in the
  inbox whose name does NOT end in `.ping`, then rename it to the event's
  `.ping` filename. Never append to or continue writing a published file.
- This works for every harness because writing a file is the one capability
  every coding agent has, including sandboxed ones (codex under
  workspace-write is proven to reach /tmp/shipwright/inbox/).

The detached relay (`scripts/relay.sh`) holds an exclusive `flock` on
`/tmp/shipwright/relay.lock`; a second launch exits nonzero. Do not delete
the lock file while a relay is running. It atomically renames each inbox
file into `inbox/.claimed/` before reading it. A producer can then publish
another file with the original filename without the relay deleting that
new file. An existing claim is processed before claiming its replacement.
Pending claims survive a relay restart and are retried there; inspect both
the inbox and `.claimed/` when diagnosing pending pings.

**Coalescing:** the relay waits for a quiet window (default 6s,
`RELAY_COALESCE`) and then types ALL pending events as ONE line — a single
event as-is, or a batch `EVENTS n: <line1> | <line2> | …` — plus a separate
Enter. One coordinator turn therefore drains a whole wave instead of one turn
per ping; a lone event still flushes after the same window. The typed line
carries each event's ping content, so the coordinator routes from it directly
and reads a marker only when a line is ambiguous.

DELIVER and claim removal occur only after BOTH tmux send commands exit
successfully. This is tmux send-acknowledgment, not agent receipt, task
acceptance, or an agent-side acknowledgment. Failed sends retain the claim:
RETRY records the failed stage and attempt; after three failures, FAILED
leaves the claim for an operator and disables automatic attempts for that
event until restart. Each failure waits one second, followed by the normal
scan interval. The pi/mode-0 guard is rechecked on each pass; DEFER does not
spend a send attempt.

If text succeeds but Enter fails, the relay remembers that phase and retries
only Enter, pausing other event sends to avoid mixing them into the same
composer. An exhausted Enter failure therefore pauses all further delivery
until an operator intervenes. Inspect the pane and `.claimed/` before a
restart: clear or reconcile partially typed input deliberately, then restart
the relay to retry retained claims. Do not blindly send another Enter.

This is not a durable exactly-once channel: dedupe and phase tracking reset
on restart, and a crash between injection and consumption can replay a
claim. A failed transport status can also leave uncertain partial effects.
Reconcile the pane and markers before acting on a repeated completion.

## 2. Marker — local recovery record, ALWAYS

    <your current checkout>/.scratch/status/<task>.r2.critic.done

ONE line:

    done TS=<ISO-8601 timestamp> TASK=<task> ROUND=2 ROLE=critic HEAD=<full-reviewed-commit> RESULT=<pass|handback|checkpoint|correction> SUMMARY=<one-line summary>

Use the same event slug for marker and ping. First-round worker markers
remain compatible with `<task>.done` and may omit ROUND/ROLE. Explicit
rounds retain separate markers so a later verdict cannot erase an earlier
handback. `.scratch/` is gitignored: it is a local cross-check, not a
cross-machine handoff. The coordinator records accepted results in tracked
coordination history before moving machines.

## 3. Hand back normally

Write your usual final handoff in your pane (task report, verdict, etc.).

## Critic verdict binding — required

Every critic verdict ping MUST include the full reviewed commit hash:
`VERDICT <task>: <pass|handback> @ <full-reviewed-commit> — <summary>`.
Record the same hash as HEAD in its marker and full report. Resolve it with
`git rev-parse HEAD` in the assigned worktree before verification, and check
it again before publishing. If HEAD or the reviewed content changed during
review, do not publish PASS for the old result; stabilize and re-review.
For external/uncommitted work, also record the exact reviewed files and
their content hashes in the report: a repository HEAD alone cannot bind
external script edits. Never invent a commit covering uncommitted files.

The coordinator compares the verdict hash with the candidate head before
merging. A behavior-changing merge, rebase, or reconciliation AFTER PASS
requires a new review round and verdict for the resulting head. For purely
non-behavioral changes, the coordinator must explicitly record old/new heads
and why the exception is non-behavioral; without that note, require re-review.
This protocol check does not replace user merge authorization or the critic.

---

Coordinator side:
- The detached relay runs `scripts/relay.sh`: guarded, COALESCED typed delivery
  — injects only when the coordinator pane runs `pi` and is not in copy mode;
  otherwise `DEFER` + retain + retry. One typed line may carry several events
  (`EVENTS n: …`). Log (`/tmp/shipwright/relay.log`) vocabulary: `ARRIVE`,
  `DEFER`, `RETRY`, `FAILED`, `DELIVER` (tmux send-acknowledged), and `DUP`.
- Standing order: drain the inbox / typed batch first thing every turn — route
  from the ping lines (they carry result/summary/head) and open a marker only
  when a line is ambiguous. Never report "no news" without checking.
- Coordinator→worker direction (assignments, corrections, review pointers)
  stays exactly as is (`prompt-target` into the worker pane).
