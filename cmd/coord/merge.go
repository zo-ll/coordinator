package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
	"github.com/zo-ll/coordinator/internal/playbook"
)

// Merge a passed unit, bound to the exact reviewed state.
//
//	merge <id>  -> MERGED <id> sha=<merge-commit> [PUSHED origin/<base>]
//
// In order, refusing at the first failure: the unit is approved (or passed
// under autonomy=auto-merge); the worktree's state hash equals the one the
// critic reviewed; every `$ ` command in the brief's VERIFY passes, run in the
// worktree (a failure appends verify_failed: the unit goes to handback); the
// state hash is unchanged by those commands. Then the coordinator commits the
// reviewed state with the user's identity, merges it into the base, and pushes
// if origin exists.
func cmdMerge(args []string) int {
	id := arg(args, 0)
	if id == "" {
		return fail(2, "merge: <id> is required")
	}
	config := configPath()
	r := load()
	u := r.Units[id]
	if u == nil {
		return refuse(id, "merged", "unknown unit")
	}
	auto := cfg.Value(config, "autonomy") == "auto-merge"
	if !(u.State == model.Approved || (u.State == model.Passed && auto)) {
		if u.State == model.Passed {
			return refuse(id, "merged", "needs the user's approval (coord approve %s)", id)
		}
		return refuse(id, "merged", "cannot merge from %s", u.State)
	}
	repo := repoRoot()
	base, ok := cfg.Get(config, "merge.base")
	if !ok || base == "" {
		base = "main"
	}
	if cur, _ := git("-C", repo, "rev-parse", "--abbrev-ref", "HEAD"); cur != base {
		return refuse(id, "merged", "the repo is on %q, not the base %q", cur, base)
	}

	hash, err := stateHash(u.Worktree)
	if err != nil {
		return refuse(id, "merged", "cannot hash %s: %v", u.Worktree, err)
	}
	if hash != u.PassState {
		return refuse(id, "merged", "reviewed state %s != current %s (re-review required)", u.PassState, hash)
	}

	// VERIFY, re-run by the engine on the reviewed state
	raw, _ := os.ReadFile(u.WorkerBrief)
	timeout := 10 * time.Minute
	if v := cfg.Value(config, "verify.timeout"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			timeout = d
		}
	}
	vlog := runPath("log", id+".verify.log")
	os.Remove(vlog)
	for _, cmd := range playbook.ParseBrief(raw).Verify() {
		if code := runVerify(u.Worktree, cmd, vlog, timeout); code != 0 {
			return verifyFailed(id, cmd, code, vlog, fmt.Sprintf("verify failed: %s (exit %d)", cmd, code))
		}
	}
	if after, err := stateHash(u.Worktree); err != nil || after != hash {
		return verifyFailed(id, "(verify modified the worktree)", 0, vlog, "verify modified the worktree")
	}

	email, name := identity(repo)
	if err := gitLoud("-C", u.Worktree, "add", "-A", "--", ".", ":(exclude).scratch"); err != nil {
		return refuse(id, "merged", "cannot stage the reviewed state in %s", u.Worktree)
	}
	if err := gitLoud("-C", u.Worktree, "-c", "user.email="+email, "-c", "user.name="+name, "commit", "-q", "-m", "[coord] "+u.Goal); err != nil {
		return refuse(id, "merged", "commit failed in %s (nothing to commit?)", u.Worktree)
	}
	if _, err := git("-c", "user.email="+email, "-c", "user.name="+name, "-C", repo, "merge", "--no-ff", "--no-edit", u.Branch); err != nil {
		git("-C", repo, "merge", "--abort")
		git("-C", u.Worktree, "reset", "-q", "--soft", "HEAD~1")
		_, err := commit(func(*model.Run) ([]events.Event, error) {
			return []events.Event{{Type: "rejected", Unit: id, By: "engine",
				Text: fmt.Sprintf("merge into %s conflicted; bring the change up to date with %s in a correction round", base, base)}}, nil
		})
		if err != nil {
			return refused(err)
		}
		return refuse(id, "merged", "git merge of %s into %s conflicted (unit returned to handback)", u.Branch, base)
	}

	sha, _ := git("-C", repo, "rev-parse", "HEAD")
	if _, err := commit(func(*model.Run) ([]events.Event, error) {
		return []events.Event{{Type: "merged", Unit: id, SHA: sha}}, nil
	}); err != nil {
		return refused(err)
	}
	fmt.Printf("MERGED %s sha=%s\n", id, sha)
	if remotes, _ := git("-C", repo, "remote"); hasLine(remotes, "origin") {
		if _, err := git("-C", repo, "push", "origin", base); err == nil {
			fmt.Printf("PUSHED origin/%s\n", base)
		}
	}
	return 0
}

// runVerify runs one VERIFY command in the worktree, bounded by timeout, with
// its output appended to vlog; it returns the exit code (124 on timeout).
func runVerify(wt, command, vlog string, timeout time.Duration) int {
	f, err := os.OpenFile(vlog, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return 1
	}
	defer f.Close()
	fmt.Fprintf(f, "$ %s\n", command)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, "bash", "-c", command)
	c.Dir, c.Stdout, c.Stderr = wt, f, f
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	c.Cancel = func() error { killGroup(c.Process.Pid, syscall.SIGKILL); return nil }
	err = c.Run()
	if ctx.Err() == context.DeadlineExceeded {
		fmt.Fprintf(f, "(timed out after %s)\n", timeout)
		return 124
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	if err != nil {
		return 1
	}
	return 0
}

func verifyFailed(id, cmd string, code int, vlog, why string) int {
	_, err := commit(func(*model.Run) ([]events.Event, error) {
		return []events.Event{{Type: "verify_failed", Unit: id, Command: cmd, Exit: code, Log: vlog, Reason: why}}, nil
	})
	if err != nil {
		return refused(err)
	}
	return refuse(id, "merged", "%s (unit returned to handback; log %s)", why, vlog)
}
