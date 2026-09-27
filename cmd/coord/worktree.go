package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/zo-ll/coordinator/internal/cfg"
)

// Create a slice's worktree off the latest base.
//
//	worktree --slice <id> --slug <slug> [--repo PATH] [--base BRANCH] [--dir PATH]
//	  -> WORKTREE <id> branch=coord/<id>-<slug> path=<path>
//
// Base defaults to config merge.base, else main. Worktrees live under
// $COORD_WORKTREES/<id>-<slug>, else <repo>/.coordinator/worktrees/<id>-<slug>.
func cmdWorktree(args []string) int {
	var slice, slug, base, dir string
	repo := repoDir()
	if c := flags("worktree.sh", args, map[string]*string{
		"--slice": &slice, "--slug": &slug, "--repo": &repo, "--base": &base, "--dir": &dir,
	}, nil); c != 0 {
		return c
	}
	if slice == "" || slug == "" {
		return fail(2, "worktree.sh: --slice and --slug are required")
	}
	if base == "" {
		v, ok := cfg.Get(configPath(), "merge.base")
		if !ok {
			v = "main"
		}
		base = v
	}
	if dir == "" {
		dir = filepath.Join(env("COORD_WORKTREES", filepath.Join(repo, ".coordinator", "worktrees")), slice+"-"+slug)
	}
	branch := "coord/" + slice + "-" + slug

	if _, err := git("-C", repo, "rev-parse", "--verify", "--quiet", base+"^{commit}"); err != nil {
		return fail(1, "worktree.sh: base '%s' not found in %s", base, repo)
	}
	if _, err := os.Lstat(dir); err == nil {
		return fail(1, "worktree.sh: path already exists: %s", dir)
	}
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return fail(1, "worktree.sh: %v", err)
	}
	var err error
	if _, e := git("-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch); e == nil {
		err = gitLoud("-C", repo, "worktree", "add", "-q", dir, branch)
	} else {
		err = gitLoud("-C", repo, "worktree", "add", "-q", "-b", branch, dir, base)
	}
	if err != nil {
		return fail(1, "worktree.sh: git worktree add failed for %s", branch)
	}
	fmt.Printf("WORKTREE %s branch=%s path=%s\n", slice, branch, dir)
	return 0
}
