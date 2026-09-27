package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// stateHash is the reviewed-state hash of a worktree: SHA-256 of the whole
// working tree (tracked changes and untracked, non-ignored files, outside
// .scratch/) against HEAD. It is computed through a throwaway index, so it
// does not depend on what the worker staged and never touches the real one.
func stateHash(wt string) (string, error) {
	dir, err := os.MkdirTemp("", "coord-index-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	idx := []string{"GIT_INDEX_FILE=" + filepath.Join(dir, "index")}
	if _, err := gitRaw(idx, "-C", wt, "read-tree", "HEAD"); err != nil {
		return "", fmt.Errorf("read-tree: %w", err)
	}
	if _, err := gitRaw(idx, "-C", wt, "add", "-A", "--", ".", ":(exclude).scratch"); err != nil {
		return "", fmt.Errorf("add: %w", err)
	}
	diff, err := gitRaw(idx, "-C", wt, "diff", "--cached", "--binary", "HEAD")
	if err != nil {
		return "", fmt.Errorf("diff: %w", err)
	}
	sum := sha256.Sum256(diff)
	return hex.EncodeToString(sum[:]), nil
}
