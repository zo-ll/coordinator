package main

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
