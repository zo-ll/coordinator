package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/ledger"
)

// Merge a passed slice. The review was of the WORKING-TREE STATE (workers
// only stage), so approval binds to a diff hash, not a commit: merge
// recomputes the reviewed state, authors the commit on the slice branch with
// the user's identity, merges it, and pushes if origin exists.
//
//	merge --slice <id>  -> MERGE <id> base=<b> sha=<merge-commit>
//	                       [PUSH <base> -> origin/<base>]
//
// Refuses unless: the verdict is pass, the recorded reviewed-state hash still
// matches the worktree, nothing is unstaged or untracked (outside .scratch/),
// and (unless autonomy=auto-merge) an approval exists at
// $COORD_ROOT/approvals/<id>.
func cmdMerge(args []string) int {
	var slice string
	if c := flags("merge.sh", args, map[string]*string{"--slice": &slice}, nil); c != 0 {
		return c
	}
	if slice == "" {
		return fail(2, "merge.sh: --slice is required")
	}
	config, repo := configPath(), repoDir()
	l := ledger.Ledger{Log: eventLog()}
	get := func(field string) string {
		n, _ := ledger.Field(field)
		v, _ := l.Get(slice, n)
		return v
	}
	verdict, head, wt, branch := get("verdict"), get("head"), get("worktree"), get("branch")

	if verdict != "pass" {
		if verdict == "" {
			verdict = "none"
		}
		return fail(1, "merge: slice %s has no PASS verdict (got '%s')", slice, verdict)
	}
	if wt == "" || branch == "" {
		return fail(1, "merge: slice %s has no worktree/branch", slice)
	}
	if cfg.Value(config, "autonomy") != "auto-merge" && !isFile(filepath.Join(coordRoot(), "approvals", slice)) {
		return fail(1, "merge: no recorded user approval for %s", slice)
	}
	if _, err := git("-C", wt, "rev-parse", "HEAD"); err != nil {
		return fail(1, "merge: cannot read HEAD in %s", wt)
	}

	// the review was of the working-tree state, not a commit: recompute the
	// exact reviewed state (diff vs the slice base) and refuse on any drift.
	diff, _ := gitRaw("-C", wt, "diff", "HEAD")
	sum := sha256.Sum256(diff)
	if hash := hex.EncodeToString(sum[:]); hash != head {
		return fail(1, "merge: reviewed state %s != current %s (re-review required)", head, hash)
	}
	if names, _ := git("-C", wt, "diff", "--name-only"); names != "" {
		return fail(1, "merge: unstaged tracked changes in %s (workers must stage everything)", wt)
	}
	st, _ := git("-C", wt, "status", "--porcelain")
	for _, line := range strings.Split(st, "\n") {
		if p, ok := strings.CutPrefix(line, "?? "); ok && !strings.HasPrefix(p, ".scratch/") {
			return fail(1, "merge: untracked files (outside .scratch/) were never staged")
		}
	}

	base, ok := cfg.Get(config, "merge.base")
	if !ok {
		base = "main"
	}
	if _, err := git("-C", repo, "rev-parse", "--verify", "--quiet", base+"^{commit}"); err != nil {
		return fail(1, "merge: base '%s' not found in %s", base, repo)
	}
	email, name := identity(repo)

	// the coordinator authors the commit on the slice branch (user's identity only)
	goal, ok := l.Get(slice, ledger.FGoal)
	if !ok {
		goal = slice
	}
	if err := gitLoud("-C", wt, "-c", "user.email="+email, "-c", "user.name="+name, "commit", "-q", "-m", "[coord] "+goal); err != nil {
		return fail(1, "merge: commit failed in %s", wt)
	}
	if _, err := git("-c", "user.email="+email, "-c", "user.name="+name, "-C", repo, "merge", "--no-ff", "--no-edit", branch); err != nil {
		return fail(1, "merge: git merge failed for %s", branch)
	}

	sha, _ := git("-C", repo, "rev-parse", "HEAD")
	l.Record(events.Event{Type: "merged", Unit: slice, SHA: sha})
	fmt.Printf("MERGE %s base=%s sha=%s\n", slice, base, sha)
	if remotes, _ := git("-C", repo, "remote"); hasLine(remotes, "origin") {
		if _, err := git("-C", repo, "push", "origin", base); err == nil {
			fmt.Printf("PUSH %s -> origin/%s\n", base, base)
		}
	}
	return 0
}

// identity is the repo user's git identity, with the coordinator's fallback.
func identity(repo string) (email, name string) {
	email, err := git("-C", repo, "config", "user.email")
	if err != nil || email == "" {
		email = "coord@local"
	}
	name, err = git("-C", repo, "config", "user.name")
	if err != nil || name == "" {
		name = "coordinator"
	}
	return email, name
}

func hasLine(s, want string) bool {
	for _, l := range strings.Split(s, "\n") {
		if l == want {
			return true
		}
	}
	return false
}
