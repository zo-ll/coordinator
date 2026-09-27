package main

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/zo-ll/coordinator/internal/cfg"
)

// Start a coordinated run: resolve the harness's REAL session id (never an
// invented one — a resume can only wake a session that actually exists),
// record it, and start the relay.
//
//	start [--harness H] [--session ID] [--no-relay]
//	  -> SESSION <id> source=<user|env|pi-env|codex-sessions|claude-projects> harness=<h> repo=<repo>
//	     [RELAY pid=<pid>]
//
// Session id resolution: --session, then COORD_SESSION, then the harness's
// own current session (pi: $PI_SESSION_ID; codex: the newest rollout in
// $CODEX_HOME/sessions; claude: the newest transcript under
// $CLAUDE_CONFIG_DIR/projects). Unresolvable is a loud failure.
func cmdStart(args []string) int {
	var harness, session string
	var noRelay bool
	if c := flags("coord.sh", args, map[string]*string{"--harness": &harness, "--session": &session},
		map[string]*bool{"--no-relay": &noRelay}); c != 0 {
		return c
	}
	ec, repo, root := envConf(), repoDir(), coordRoot()
	if harness == "" {
		harness = cfg.Value(ec, "current")
	}
	if harness == "" {
		return fail(1, "coord: no current harness (run detect.sh first)")
	}
	id, src := resolveSession(harness, session)
	if id == "" {
		fmt.Fprintf(os.Stderr, "coord: no resumable session id for harness '%s' — no invented ids.\n", harness)
		fmt.Fprintln(os.Stderr, "  pi:       relies on $PI_SESSION_ID")
		fmt.Fprintln(os.Stderr, "  codex:    scans ${CODEX_HOME:-~/.codex}/sessions for the live rollout")
		fmt.Fprintln(os.Stderr, "  claude:   scans ${CLAUDE_CONFIG_DIR:-~/.claude}/projects for the live jsonl")
		fmt.Fprintln(os.Stderr, "  opencode: no machine-readable id yet; pass --session from the TUI")
		fmt.Fprintln(os.Stderr, "  fallback: pass --session <the harness's real session id>")
		return 1
	}

	cdir := filepath.Join(repo, ".coordinator")
	if err := os.MkdirAll(cdir, 0o755); err != nil {
		return fail(1, "coord: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cdir, "session"), []byte(id+"\n"), 0o644); err != nil {
		return fail(1, "coord: %v", err)
	}
	fmt.Printf("SESSION %s source=%s harness=%s repo=%s\n", id, src, harness, repo)

	// repo hygiene: workers use `git add -A`, so keep finish markers out of
	// the index from the start — the first commit the coordinator authors.
	gi := filepath.Join(repo, ".gitignore")
	if !hasLine(readTrim(gi), ".scratch/") {
		appendLine(gi, ".scratch/")
		hygieneCommit(repo, ".gitignore", "[coord] ignore .scratch markers")
	}

	// claude grants permissions per process and per allowed directory, so
	// auto-resumed coordinator turns and -p workers are write-blocked. A
	// project settings file with bypassPermissions gives every claude process
	// in the repo full permissions — the worker policy, uniformly.
	cs := filepath.Join(repo, ".claude", "settings.local.json")
	if b, err := os.ReadFile(cs); err == nil {
		if !strings.Contains(string(b), "bypassPermissions") {
			fmt.Fprintf(os.Stderr, "coord: claude settings exist without bypassPermissions: %s (merge policy requires full worker perms)\n", cs)
		}
	} else if _, err := os.Lstat(cs); os.IsNotExist(err) {
		os.MkdirAll(filepath.Dir(cs), 0o755)
		os.WriteFile(cs, []byte("{\n  \"permissions\": {\n    \"defaultMode\": \"bypassPermissions\"\n  }\n}\n"), 0o644)
		hygieneCommit(repo, ".claude/settings.local.json", "[coord] claude full permissions")
	}

	if noRelay {
		return 0
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return fail(1, "coord: %v", err)
	}
	// pin the resume recipe so the relay never depends on env.conf `current`,
	// which may be unresolved in the coordinator's shell; config is explicit.
	cfgf := filepath.Join(cdir, "config.conf")
	if !isFile(cfgf) {
		os.WriteFile(cfgf, nil, 0o644)
	}
	if rec := cfg.Value(ec, "harness."+harness+".resume"); rec != "" {
		cfg.Set(cfgf, "relay.resume", rec)
	}
	pid, err := startRelay(root, cfgf, id)
	if err != nil {
		return fail(1, "coord: cannot start relay: %v", err)
	}
	os.WriteFile(filepath.Join(root, "relay.pid"), []byte(fmt.Sprintf("%d\n", pid)), 0o644)
	fmt.Printf("RELAY pid=%d\n", pid)
	return 0
}

func startRelay(root, config, session string) (int, error) {
	exe, err := os.Executable()
	if err != nil {
		return 0, err
	}
	logf, err := os.OpenFile(filepath.Join(root, "relay.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return 0, err
	}
	defer logf.Close()
	c := exec.Command(exe, "relay")
	c.Env = append(os.Environ(), "COORD_CONFIG="+config, "COORD_SESSION="+session, "COORD_SCRIPTS="+scriptsDir())
	c.Stdout, c.Stderr = logf, logf
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return 0, err
	}
	pid := c.Process.Pid
	c.Process.Release()
	return pid, nil
}

func resolveSession(harness, flag string) (id, source string) {
	if flag != "" {
		return flag, "user"
	}
	if v := os.Getenv("COORD_SESSION"); v != "" {
		return v, "env"
	}
	home := os.Getenv("HOME")
	switch harness {
	case "pi":
		if v := os.Getenv("PI_SESSION_ID"); v != "" {
			return v, "pi-env"
		}
	case "codex":
		dir := filepath.Join(env("CODEX_HOME", filepath.Join(home, ".codex")), "sessions")
		if f := newest(dir, func(n string) bool { return strings.HasPrefix(n, "rollout-") && strings.HasSuffix(n, ".jsonl") }); f != "" {
			parts := strings.Split(strings.TrimSuffix(filepath.Base(f), ".jsonl"), "-")
			if len(parts) >= 5 {
				parts = parts[len(parts)-5:]
			}
			return strings.Join(parts, "-"), "codex-sessions"
		}
	case "claude":
		dir := filepath.Join(env("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude")), "projects")
		if f := newest(dir, func(n string) bool { return strings.HasSuffix(n, ".jsonl") }); f != "" {
			return strings.TrimSuffix(filepath.Base(f), ".jsonl"), "claude-projects"
		}
	case "opencode":
		// sessions live in a sqlite store with no reliable read access here;
		// require the coordinator to pass --session explicitly.
	}
	return "", ""
}

// newest returns the most recently modified file under dir whose name matches.
func newest(dir string, match func(string) bool) string {
	var best string
	var bestT time.Time
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !match(d.Name()) {
			return nil
		}
		if info, err := d.Info(); err == nil && info.ModTime().After(bestT) {
			best, bestT = p, info.ModTime()
		}
		return nil
	})
	return best
}

// appendLine appends line, first terminating an unterminated last line.
func appendLine(path, line string) {
	b, _ := os.ReadFile(path)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if len(b) > 0 && b[len(b)-1] != '\n' {
		f.WriteString("\n")
	}
	f.WriteString(line + "\n")
}
