package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
	"github.com/zo-ll/coordinator/internal/playbook"
)

// Dispatch one role for a unit, detached, in the unit's worktree.
//
//	dispatch <id> --role worker --brief <file>
//	dispatch <id> --role critic
//	  -> DISPATCHED <id> role=<r> round=<n> slug=<s> pid=<p> wt=<path> log=<path>
//
// The engine computes the round and the finish slug the launch owes, creates
// the worktree on the first worker round, refuses a worker brief missing a
// field its playbook requires (or whose VERIFY has no `$ ` command), and
// writes the critic's brief itself from the worker brief. A stalled launch is
// re-dispatched for the same round (the worker brief is reused if omitted).
//
// The launched prompt: role preamble, the playbook's section for the role, the
// brief, the standing orders (.coordinator/standing.md), the finish contract.
func cmdDispatch(args []string) int {
	id := arg(args, 0)
	if id == "" || strings.HasPrefix(id, "--") {
		return fail(2, "dispatch: <id> is required")
	}
	var role, briefPath string
	if c := flags("dispatch", args[1:], map[string]*string{"--role": &role, "--brief": &briefPath}, nil); c != 0 {
		return c
	}
	if role != "worker" && role != "critic" {
		return fail(2, "dispatch: --role worker|critic is required")
	}

	r := load()
	u := r.Units[id]
	if u == nil {
		return refuse(id, "dispatched", "unknown unit")
	}
	pb, err := playbook.Load(u.Kind, playbookDirs()...)
	if err != nil {
		return refuse(id, "dispatched", "%v", err)
	}
	round, err := r.NextRound(u, role)
	if err != nil {
		return refuse(id, "dispatched", "%v", err)
	}
	slug := model.Slug(id, round, role)
	config := configPath()

	var body []byte
	var rawBrief string
	timebox := pb.Timebox
	switch role {
	case "worker":
		if briefPath == "" && u.State == model.Stalled {
			briefPath = u.WorkerBrief
		}
		if briefPath == "" {
			return fail(2, "dispatch: a worker needs --brief <file>")
		}
		raw, err := os.ReadFile(briefPath)
		if err != nil {
			return refuse(id, "brief", "not readable: %s", briefPath)
		}
		b := playbook.ParseBrief(raw)
		if missing := b.Missing(pb.Require); len(missing) > 0 {
			return refuse(id, "brief", "missing %s (a %s brief needs: %s)", strings.Join(missing, " "), u.Kind, strings.Join(pb.Require, " "))
		}
		if b.Has("VERIFY") && len(b.Verify()) == 0 {
			return refuse(id, "brief", `VERIFY has no "$ " command`)
		}
		if timebox, err = b.Timebox(pb.Timebox); err != nil {
			return refuse(id, "brief", "%v", err)
		}
		rawBrief = runPath("briefs", slug+".brief.md")
		if err := writeFile(rawBrief, raw); err != nil {
			return fail(1, "dispatch: %v", err)
		}
		body = raw
	case "critic":
		if briefPath != "" {
			return fail(2, "dispatch: a critic's brief is written by the engine; drop --brief")
		}
		raw, err := os.ReadFile(u.WorkerBrief)
		if err != nil {
			return refuse(id, "dispatched", "worker brief unreadable: %s", u.WorkerBrief)
		}
		body = []byte(criticBrief(u, round, pb, playbook.ParseBrief(raw)))
	}

	// harness: critic.*; a worker's lane is routing.<risk>, else the playbook's
	hkey, mkey := "critic.harness", "critic.model"
	if role == "worker" {
		lane := pb.Lane
		if u.Risk != "" {
			v, ok := cfg.Get(config, "routing."+u.Risk)
			if !ok {
				return refuse(id, "dispatched", "no routing.%s in %s", u.Risk, config)
			}
			lane = v
		}
		hkey, mkey = "lane."+lane+".harness", "lane."+lane+".model"
	}
	harness, ok := cfg.Get(config, hkey)
	if !ok || harness == "" {
		return refuse(id, "dispatched", "no %s in %s", hkey, config)
	}
	mdl := cfg.Value(config, mkey)

	// the worktree: created on the unit's first worker round, reused after
	wt, branch, base := u.Worktree, u.Branch, u.Base
	fresh := wt == ""
	if fresh {
		if wt, branch, base, err = makeWorktree(id, config); err != nil {
			return refuse(id, "dispatched", "%v", err)
		}
	}

	logPath := eventsPath()
	var section string
	if role == "worker" {
		section = pb.Worker
	} else {
		section = pb.Critic
	}
	prompt := compose(section, body, finishContract(role, slug, logPath, pb, ""))
	promptPath := runPath("briefs", slug+".md")
	if err := writeFile(promptPath, prompt); err != nil {
		return fail(1, "dispatch: %v", err)
	}
	argv, err := buildArgv(harness, role, promptPath, wt, mdl)
	if err != nil || len(argv) == 0 {
		return refuse(id, "dispatched", "no argv for harness %q: %v", harness, err)
	}
	logf := runPath("log", slug+".log")
	pid, err := launch(config, role, wt, logf, roleEnv(logPath, slug), argv)
	if err != nil {
		return refuse(id, "dispatched", "cannot launch %s: %v", argv[0], err)
	}

	e := events.Event{Type: "dispatched", Unit: id, Role: role, Round: round, Slug: slug, PID: pid,
		Harness: harness, Model: mdl, TimeboxS: int(timebox / time.Second), Log: logf, Brief: rawBrief}
	if fresh {
		e.Worktree, e.Branch, e.Base = wt, branch, base
	}
	if _, err := commit(func(*model.Run) ([]events.Event, error) { return []events.Event{e}, nil }); err != nil {
		killGroup(pid, syscall.SIGTERM) // lost a race: never leave an unrecorded launch running
		return refused(err)
	}
	fmt.Printf("DISPATCHED %s role=%s round=%d slug=%s pid=%d wt=%s log=%s\n", id, role, round, slug, pid, wt, logf)
	return 0
}

// Dispatch a researcher: no unit, no worktree; it writes a decision brief.
//
//	research --brief <file>  -> RESEARCH <slug> pid=<p> report=<path> log=<path>
func cmdResearch(args []string) int {
	var briefPath string
	if c := flags("research", args, map[string]*string{"--brief": &briefPath}, nil); c != 0 {
		return c
	}
	raw, err := os.ReadFile(briefPath)
	if err != nil {
		return fail(2, "research: --brief <file> is required and readable")
	}
	b := playbook.ParseBrief(raw)
	if !b.Has("GOAL") {
		return refuse("", "brief", "missing GOAL (a research brief needs: GOAL)")
	}
	timebox, err := b.Timebox(30 * time.Minute)
	if err != nil {
		return refuse("", "brief", "%v", err)
	}
	config := configPath()
	harness := cfg.Value(config, "researcher.harness")
	if harness == "" {
		return refuse("", "dispatched", "no researcher.harness in %s", config)
	}
	n := 1
	if log, _ := eventLog().Read(); log != nil {
		for _, e := range log {
			if e.Type == "dispatched" && e.Role == "researcher" {
				n++
			}
		}
	}
	slug := fmt.Sprintf("research.%d", n)
	report := runPath("research", fmt.Sprintf("%d.md", n))
	os.MkdirAll(filepath.Dir(report), 0o755)
	logPath := eventsPath()
	prompt := compose("", raw, finishContract("researcher", slug, logPath, nil, report))
	promptPath := runPath("briefs", slug+".md")
	if err := writeFile(promptPath, prompt); err != nil {
		return fail(1, "research: %v", err)
	}
	argv, err := buildArgv(harness, "researcher", promptPath, repoRoot(), cfg.Value(config, "researcher.model"))
	if err != nil || len(argv) == 0 {
		return refuse("", "dispatched", "no argv for harness %q: %v", harness, err)
	}
	logf := runPath("log", slug+".log")
	pid, err := launch(config, "researcher", repoRoot(), logf, roleEnv(logPath, slug), argv)
	if err != nil {
		return refuse("", "dispatched", "cannot launch %s: %v", argv[0], err)
	}
	e := events.Event{Type: "dispatched", Role: "researcher", Slug: slug, PID: pid, Report: report,
		Harness: harness, TimeboxS: int(timebox / time.Second), Log: logf}
	if _, err := commit(func(*model.Run) ([]events.Event, error) { return []events.Event{e}, nil }); err != nil {
		killGroup(pid, syscall.SIGTERM)
		return refused(err)
	}
	fmt.Printf("RESEARCH %s pid=%d report=%s log=%s\n", slug, pid, report, logf)
	return 0
}

// criticBrief is the critic's assignment, composed from the worker brief's
// criteria only: GOAL, SCOPE, REPRO, ACCEPTANCE, VERIFY. CONTEXT and any other
// coordinator prose never reach the critic.
func criticBrief(u *model.Unit, round int, pb *playbook.Playbook, wb playbook.Brief) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Review unit %s (%s), round %d, in the worktree %s.\n", u.ID, u.Kind, round, u.Worktree)
	b.WriteString("The change under review is the whole working tree against HEAD: `git diff HEAD`\n")
	b.WriteString("plus untracked files (the worker never commits). Judge it against these\n")
	b.WriteString("criteria only; you do not see the worker's or the coordinator's reasoning.\n\n")
	for _, f := range []string{"GOAL", "SCOPE", "REPRO", "ACCEPTANCE", "VERIFY"} {
		if wb.Has(f) {
			b.WriteString(wb.Section(f) + "\n\n")
		}
	}
	b.WriteString("Do not edit tracked files, commit, push, or merge. Run the checks yourself.\n")
	return b.String()
}

// finishContract is the generated last section of every prompt.
func finishContract(role, slug, logPath string, pb *playbook.Playbook, report string) string {
	call := fmt.Sprintf("COORD_EVENTS=%s COORD_OWES=%s %s finish", logPath, slug, self())
	var b strings.Builder
	b.WriteString("FINISH CONTRACT (do not skip; this is the completion protocol):\n")
	switch role {
	case "worker":
		fmt.Fprintf(&b, "%s --result done --summary \"<one line>\"\n", call)
		b.WriteString("If you cannot complete it (out of time, blocked, brief conflicts with the repo),\n")
		b.WriteString("finish with --result partial and say what is left in the summary.\n")
	case "critic":
		fmt.Fprintf(&b, "%s --result pass|handback --evidence <%s> --ran \"<command>\" [--ran \"<command>\"]...", call, strings.Join(playbook.Levels, "|"))
		for _, f := range pb.Need {
			fmt.Fprintf(&b, " --flag %s", f)
		}
		b.WriteString(" --summary \"<one line>\"\n")
		fmt.Fprintf(&b, "Evidence is the strongest level you proved yourself (%s). This unit needs at\n", strings.Join(playbook.Levels, " < "))
		fmt.Fprintf(&b, "least %s", pb.Floor)
		if pb.Floor != "none" {
			b.WriteString(", with every command you ran as --ran")
		}
		for _, f := range pb.Need {
			fmt.Fprintf(&b, ", and --flag %s only if you proved it", f)
		}
		b.WriteString(". A pass below that comes back as a handback.\n")
	case "researcher":
		fmt.Fprintf(&b, "Write your decision brief to %s, then:\n", report)
		fmt.Fprintf(&b, "%s --result done --summary \"<one line>\"\n", call)
	}
	return b.String()
}

// compose joins the prompt parts with blank lines, adding standing orders.
func compose(section string, body []byte, contract string) []byte {
	var b bytes.Buffer
	if s := strings.TrimSpace(section); s != "" {
		b.WriteString(s + "\n\n")
	}
	b.Write(bytes.TrimRight(body, "\n"))
	b.WriteString("\n")
	if p := runPath("standing.md"); nonEmpty(p) {
		orders, _ := os.ReadFile(p)
		b.WriteString("\nSTANDING ORDERS (apply to everything you do):\n")
		b.Write(bytes.TrimRight(orders, "\n"))
		b.WriteString("\n")
	}
	b.WriteString("\n" + contract)
	return b.Bytes()
}

func roleEnv(logPath, slug string) []string {
	return append(os.Environ(), "COORD_EVENTS="+logPath, "COORD_OWES="+slug)
}

func writeFile(p string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o644)
}

// makeWorktree creates <run>/worktrees/<id> on branch coord/<id> off the
// base (config merge.base, else main), reusing the branch if it exists.
func makeWorktree(id, config string) (wt, branch, base string, err error) {
	repo := repoRoot()
	baseRef, ok := cfg.Get(config, "merge.base")
	if !ok || baseRef == "" {
		baseRef = "main"
	}
	base, err = git("-C", repo, "rev-parse", "--verify", "--quiet", baseRef+"^{commit}")
	if err != nil {
		return "", "", "", fmt.Errorf("base %q not found in %s", baseRef, repo)
	}
	wt, branch = runPath("worktrees", id), "coord/"+id
	if _, err := os.Lstat(wt); err == nil {
		// left by a dispatch that never got recorded: reuse it if it is ours
		if cur, _ := git("-C", wt, "rev-parse", "--abbrev-ref", "HEAD"); cur == branch {
			return wt, branch, base, nil
		}
		return "", "", "", fmt.Errorf("worktree path already exists: %s", wt)
	}
	os.MkdirAll(filepath.Dir(wt), 0o755)
	if _, e := git("-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch); e == nil {
		err = gitLoud("-C", repo, "worktree", "add", "-q", wt, branch)
	} else {
		err = gitLoud("-C", repo, "worktree", "add", "-q", "-b", branch, wt, base)
	}
	if err != nil {
		return "", "", "", fmt.Errorf("git worktree add failed for %s", branch)
	}
	return wt, branch, base, nil
}

// launch runs argv through the first enabled adapter that accepts it
// (adapters/<name>.sh defining adapter_launch <cwd> <log> <argv…> -> pid),
// else detached under setsid with output appended to logf.
func launch(config, role, wt, logf string, envv, argv []string) (int, error) {
	if err := os.MkdirAll(filepath.Dir(logf), 0o755); err != nil {
		return 0, err
	}
	adapters := env("COORD_ADAPTERS", filepath.Join(skillRoot(), "adapters"))
	list := strings.FieldsFunc(cfg.Value(config, "adapters"), func(r rune) bool { return r == ',' || r == ' ' || r == '\t' })
	for _, name := range list {
		a := filepath.Join(adapters, name+".sh")
		if name == "none" || !isFile(a) {
			continue
		}
		c := exec.Command("bash", append([]string{"-c", `set -uo pipefail; . "$1"; shift; adapter_launch "$@"`, "coord-adapter", a, wt, logf}, argv...)...)
		c.Env = append(envv, "ADAPTER_NAME="+role)
		c.Stderr = os.Stderr
		if out, err := c.Output(); err == nil {
			var pid int
			if _, err := fmt.Sscanf(strings.TrimSpace(string(out)), "%d", &pid); err == nil && pid > 0 {
				return pid, nil
			}
		}
	}

	f, err := os.OpenFile(logf, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	c := exec.Command(argv[0], argv[1:]...)
	c.Dir, c.Env = wt, envv
	c.Stdout, c.Stderr = f, f
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return 0, err
	}
	pid := c.Process.Pid
	c.Process.Release()
	return pid, nil
}
