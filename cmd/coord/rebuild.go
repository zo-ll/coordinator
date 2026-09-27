package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
)

// rebuildIfStale keeps `git pull` live: when a Go source in the skill is
// newer than this binary and go is on PATH, rebuild in place and re-exec.
// Without go, a stale binary keeps running. COORD_NO_REBUILD=1 disables it.
func rebuildIfStale() {
	if os.Getenv("COORD_NO_REBUILD") != "" || os.Getenv("COORD_REBUILT") != "" {
		return
	}
	bin := self()
	root := filepath.Dir(filepath.Dir(bin))
	st, err := os.Stat(bin)
	if err != nil || !isFile(filepath.Join(root, "go.mod")) {
		return
	}
	stale := false
	for _, pat := range []string{"go.mod", "cmd/coord/*.go", "internal/*/*.go"} {
		files, _ := filepath.Glob(filepath.Join(root, pat))
		for _, f := range files {
			if fi, err := os.Stat(f); err == nil && fi.ModTime().After(st.ModTime()) {
				stale = true
			}
		}
	}
	if !stale {
		return
	}
	goBin, err := exec.LookPath("go")
	if err != nil {
		return
	}
	tmp := bin + "." + strconv.Itoa(os.Getpid())
	c := exec.Command(goBin, "build", "-o", tmp, "./cmd/coord")
	c.Dir, c.Stdout, c.Stderr = root, os.Stderr, os.Stderr
	if c.Run() != nil || os.Rename(tmp, bin) != nil {
		os.Remove(tmp)
		return
	}
	syscall.Exec(bin, os.Args, append(os.Environ(), "COORD_REBUILT=1"))
}
