package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/ledger"
)

// Launch one role, detached, in its worktree, and record the dispatch.
//
//	spawn --role <critic|researcher|worker> --prompt <brief> --worktree <dir>
//	      [--slice <id>] [--risk <class>]
//	  -> SPAWN <role> slice=<id> pid=<pid> wt=<path> log=<path>
//
// Role -> harness/model comes from config.conf (critic.*, researcher.*, or
// lane.<lane>.* for a worker, where <lane> = routing.<risk>; no --risk means
// lane.default). Output goes to $COORD_ROOT/log/<role>[.<slice>].log.
//
// The brief is refused unless it carries its role's header lines (`FIELD:` at
// line start): worker GOAL SCOPE ACCEPTANCE VERIFY; critic ACCEPTANCE;
// researcher GOAL. A field you cannot fill is a slice you have not scoped.
//
// The launched prompt is: brief, then the standing orders ($COORD_STANDING,
// default <config dir>/standing.md) verbatim, then the finish contract.
func cmdSpawn(args []string) int {
	var role, prompt, wt, slice, risk string
	if c := flags("spawn.sh", args, map[string]*string{
		"--role": &role, "--prompt": &prompt, "--worktree": &wt, "--slice": &slice, "--risk": &risk,
	}, nil); c != 0 {
		return c
	}
	if role == "" || prompt == "" || wt == "" {
		return fail(2, "spawn.sh: --role, --prompt and --worktree are required")
	}
	brief, err := os.ReadFile(prompt)
	if err != nil {
		return fail(1, "spawn.sh: prompt file not readable: %s", prompt)
	}
	// a worker or critic IS a slice round; without --slice the finish contract
	// cannot be appended and the role cannot be recorded (see issue #5)
	if role != "researcher" && slice == "" {
		return fail(2, "spawn.sh: --slice is required for role '%s' (finish contract + ledger)", role)
	}
	if risk != "" && role != "worker" {
		return fail(2, "spawn.sh: --risk applies to workers only")
	}

	config := configPath()
	var hkey, mkey, need string
	switch role {
	case "critic":
		hkey, mkey, need = "critic.harness", "critic.model", "ACCEPTANCE"
	case "researcher":
		hkey, mkey, need = "researcher.harness", "researcher.model", "GOAL"
	case "worker":
		lane := "default"
		if risk != "" {
			v, ok := cfg.Get(config, "routing."+risk)
			if !ok {
				return fail(1, "spawn.sh: no routing.%s in %s", risk, config)
			}
			lane = v
		}
		hkey, mkey, need = "lane."+lane+".harness", "lane."+lane+".model", "GOAL SCOPE ACCEPTANCE VERIFY"
	default:
		return fail(2, "spawn.sh: unknown role: %s", role)
	}

	var missing []string
	for _, f := range strings.Fields(need) {
		if !regexp.MustCompile(`(?m)^` + f + `:`).Match(brief) {
			missing = append(missing, f)
		}
	}
	if len(missing) > 0 {
		return fail(1, "spawn.sh: brief missing %s (a %s brief needs: %s)", strings.Join(missing, " "), role, need)
	}

	// The composed prompt: the brief, the standing orders verbatim (directives
	// decay across rounds unless every launch carries them), then the finish
	// contract. The finish contract is MECHANICAL: it must not depend on the
	// coordinator remembering to write it — the worker's --event is the slice id
	// (plus round), the critic's is the same plus .critic, filled in by the critic.
	sent := bytes.NewBuffer(append([]byte(nil), brief...))
	standing := env("COORD_STANDING", filepath.Join(filepath.Dir(config), "standing.md"))
	if nonEmpty(standing) {
		orders, _ := os.ReadFile(standing)
		sent.WriteString("\nSTANDING ORDERS (apply to everything you do):\n")
		sent.Write(orders)
	}

	l := ledger.Ledger{Path: ledgerPath()}
	finish := filepath.Join(scriptsDir(), "finish.sh")
	fslug := ""
	if slice != "" {
		wslug := slice
		rv, _ := l.Get(slice, 4)
		if n, err := strconv.Atoi(rv); err == nil && n > 1 {
			wslug = fmt.Sprintf("%s.r%d", slice, n)
		}
		switch role {
		case "worker":
			fslug = wslug
			fmt.Fprintf(sent, "\nFINISH CONTRACT (do not skip; this is the completion protocol):\n"+
				"%s --event %s --role worker --result done --head - --summary \"<one line>\"\n", finish, fslug)
		case "critic":
			fslug = wslug + ".critic"
			fmt.Fprintf(sent, "\nFINISH CONTRACT (do not skip; this is the completion protocol):\n"+
				"%s --event %s --role critic --result <pass|handback> --head <hash>\n"+
				"where <hash> = git diff HEAD | sha256sum | cut -d' ' -f1, run in this worktree.\n", finish, fslug)
		}
	}
	sentPath := prompt + ".sent"
	if err := os.WriteFile(sentPath, sent.Bytes(), 0o644); err != nil {
		return fail(1, "spawn.sh: %v", err)
	}

	h, ok := cfg.Get(config, hkey)
	if !ok {
		return fail(1, "spawn.sh: no %s in %s", hkey, config)
	}
	argv, err := buildArgv(h, role, sentPath, wt, cfg.Value(config, mkey))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	if len(argv) == 0 {
		return fail(1, "spawn.sh: no argv for role '%s' (harness '%s'): check the exec recipe and the brief", role, h)
	}

	logdir := filepath.Join(coordRoot(), "log")
	if err := os.MkdirAll(logdir, 0o755); err != nil {
		return fail(1, "spawn.sh: %v", err)
	}
	name := role
	if slice != "" {
		name += "." + slice
	}
	logf := filepath.Join(logdir, name+".log")

	pid, err := launch(config, role, wt, logf, argv)
	if err != nil {
		return fail(1, "spawn.sh: cannot launch %s: %v", argv[0], err)
	}

	if slice != "" {
		// task = the finish slug this launch owes; the relay reports a DIED
		// event when the pid is gone and that slug was never enqueued
		branch, _ := git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD")
		l.Set(slice, map[int]string{1: "dispatched", 3: fslug, 5: wt, 6: branch, 7: pid})
	}
	fmt.Printf("SPAWN %s slice=%s pid=%s wt=%s log=%s\n", role, orNone(slice), pid, wt, logf)
	return 0
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// launch runs argv through the first enabled adapter that accepts it
// (adapters/<name>.sh defining adapter_launch <cwd> <log> <argv…> -> pid),
// else detached under setsid with output appended to logf.
func launch(config, role, wt, logf string, argv []string) (string, error) {
	adapters := env("COORD_ADAPTERS", filepath.Join(filepath.Dir(scriptsDir()), "adapters"))
	list := strings.FieldsFunc(cfg.Value(config, "adapters"), func(r rune) bool { return r == ',' || r == ' ' || r == '\t' })
	for _, name := range list {
		if name == "none" {
			continue
		}
		a := filepath.Join(adapters, name+".sh")
		if !isFile(a) {
			continue
		}
		c := exec.Command("bash", append([]string{"-c", `set -uo pipefail; . "$1"; shift; adapter_launch "$@"`, "coord-adapter", a, wt, logf}, argv...)...)
		c.Env = append(os.Environ(), "ADAPTER_NAME="+role)
		c.Stderr = os.Stderr
		out, err := c.Output()
		if err == nil {
			return strings.TrimRight(string(out), "\n"), nil
		}
	}

	f, err := os.OpenFile(logf, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return "", err
	}
	defer f.Close()
	c := exec.Command(argv[0], argv[1:]...)
	c.Dir = wt
	c.Stdout, c.Stderr = f, f
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return "", err
	}
	pid := strconv.Itoa(c.Process.Pid)
	c.Process.Release()
	return pid, nil
}
