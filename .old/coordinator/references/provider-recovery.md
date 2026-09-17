# Provider recovery — read-only detection, bounded intervention

Run `bash scripts/check-aborted.sh personal` from the coordinator skill
directory at supervision checkpoints and after a provider-error report.
The helper only lists panes and captures text; it never sends keys, pings,
restarts, or switches models. It selects critic/researcher/worker-named
panes and pi/Codex/Claude applications, excluding the coordinator window.
Output columns are pane ID, window name, and status:

| Status | Interpretation and next action |
| --- | --- |
| working | Latest recognizable cue is Working/thinking. Do not nudge or send Enter. |
| retry-wait | Latest cue is a rate limit or retry message without a later abort/progress cue. Allow the harness to retry; do not dispatch another turn. |
| aborted-at-idle | Latest cue says retries exhausted, with no later Working cue. Capture the pane and verify an idle prompt before recovery. |
| idle-ok | No current recognized failure/progress cue. Cross-check marker and expected task; this is not proof of completion or accepted dispatch. |
| capture-error | Pane could not be read; helper exits nonzero. Resolve the pane/session identity before deciding anything. |

Detection uses the last 80 captured lines and the most recent recognizable
cue. Old visible error text, quoted messages, unfamiliar spinners, or a
completed turn with old Working text can misclassify a pane. Treat this as
a triage hint, not an authoritative harness state API. Absence of Working
alone does not prove abort. A missing session also exits nonzero.

## Recovery protocol

1. Read the current assignment, marker, and last accepted head/verdict.
   Capture the pane to confirm whether it is retrying, actually idle after
   abort, or finished. Never equate an idle prompt with a successful task.
2. For a provider error, schedule at most three observations after delays
   of 10, 20, and 40 seconds, each with 0–5 seconds of random jitter. For
   example, use a delay of `base + RANDOM % 6`; do not hammer the provider
   or run an unbounded retry loop. A still-working/retrying turn gets no
   input. Record the task, pane, retry count, and next observation time.
3. When retries are exhausted and the pane is visibly idle, the coordinator
   may nudge ONCE for that aborted episode using a single-line pointer:
   `Resume the existing assignment at <path> from your checkpoint; do not
   repeat a completed finish event.` Capture afterward for actual progress.
   The existing dispatch rule still applies: one additional Enter only if
   that pointer is visibly unsubmitted; never while Working.
4. If the one nudge aborts again or the observation budget is exhausted,
   record a provider-blocked state and hand it to the coordinator. Do not
   loop nudges, treat a missing marker as PASS, or redispatch in parallel.
   A subsequent recovery episode needs an explicit coordinator decision.
5. Restarting the harness or switching provider/model requires coordinator
   authorization. Record the authorized model/provider, reason, reviewed
   task/head, and preserved checkpoint. There is NO automatic fallback
   model. The replacement critic still independently reviews the assigned
   head; a provider failure never relaxes the review gate.

These are operator/coordinator steps, not side effects of the detector.
Use normal tracked coordination history for accepted decisions, and keep
transient observations separate from completion events.
