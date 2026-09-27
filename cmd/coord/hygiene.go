package main

import "fmt"

// Commit a boot-hygiene file authored by the coordinator. Never fatal: with
// no HEAD, an unchanged file, or a failed commit, the file is left in place.
//
//	hygiene <repo> <path> <message>  -> DONE <message> when it committed
func cmdHygiene(args []string) int {
	repo, path, msg := arg(args, 0), arg(args, 1), arg(args, 2)
	if repo == "" || path == "" || msg == "" {
		return fail(1, "hygiene-commit.sh: <repo> <path> <message> are required")
	}
	if hygieneCommit(repo, path, msg) {
		fmt.Printf("DONE %s\n", msg)
	}
	return 0
}

// hygieneCommit force-adds path (ignored files included) and commits it with
// the user's identity if it changed.
func hygieneCommit(repo, path, msg string) bool {
	if _, err := git("-C", repo, "rev-parse", "--verify", "--quiet", "HEAD"); err != nil {
		return false
	}
	email, name := identity(repo)
	if _, err := git("-C", repo, "add", "-f", "--", path); err != nil {
		return false
	}
	if st, _ := git("-C", repo, "status", "--porcelain", "--", path); st == "" {
		return false
	}
	_, err := git("-C", repo, "-c", "user.email="+email, "-c", "user.name="+name, "commit", "-q", "-m", msg)
	return err == nil
}
