package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/fsx"
)

var (
	execRecipes = map[string]string{
		"codex":    "codex|exec|-C|__CWD__|--dangerously-bypass-approvals-and-sandbox|__PROMPT__",
		"claude":   "claude|-p|--dangerously-skip-permissions|__PROMPT__",
		"pi":       "pi|__PROMPT__",
		"opencode": "opencode|run|--auto|__PROMPT__",
	}
	resumeRecipes = map[string]string{
		"codex":    "codex|queue|--thread|__SESSION__|--message|__BATCH__",
		"claude":   "claude|-p|--resume|__SESSION__|--dangerously-skip-permissions|__BATCH__",
		"pi":       "pi|--resume|__SESSION__|__BATCH__",
		"opencode": "opencode|run|--session|__SESSION__|--auto|__BATCH__",
	}
)

// Detect the environment and write $COORD_HOME/env.conf.
//
//	detect -> DETECT current=<h> installed=<a,b> spawnable=<a,b> tmux=0|1 gh=0|1
//
// Current harness: env sentinel first, else walk the ancestor process chain.
// Installed: PATH lookup over the known list (override with COORD_KNOWN).
// Spawnable: installed AND we know an exec recipe for it.
func cmdDetect(args []string) int {
	if err := os.MkdirAll(coordHome(), 0o755); err != nil {
		return fail(1, "detect: %v", err)
	}
	known := strings.Fields(env("COORD_KNOWN", "codex claude pi opencode crush goose devin gemini"))

	current, source := "", "unknown"
	switch {
	case os.Getenv("OPENCODE") == "1":
		current, source = "opencode", "env"
	case os.Getenv("CLAUDECODE")+os.Getenv("CLAUDE_CODE_ENTRYPOINT") != "":
		current, source = "claude", "env"
	case os.Getenv("PI_CODING_AGENT_SESSION_DIR")+os.Getenv("PI_SESSION_ID") != "":
		current, source = "pi", "env"
	case os.Getenv("CODEX_HOME") != "":
		current, source = "codex", "env"
	}
	if current == "" {
		pid := os.Getppid()
	walk:
		for range 12 {
			comm := procComm(pid)
			if comm == "" {
				break
			}
			for _, h := range known {
				if comm == h {
					current, source = h, "ancestor"
					break walk
				}
			}
			if pid = procPPID(pid); pid <= 1 {
				break
			}
		}
	}

	var installed, spawnable []string
	bins := map[string]string{}
	for _, h := range known {
		if p, err := exec.LookPath(h); err == nil {
			installed = append(installed, h)
			bins[h] = p
			if _, ok := execRecipes[h]; ok {
				spawnable = append(spawnable, h)
			}
		}
	}
	has := func(tool string) string {
		_, err := exec.LookPath(tool)
		return bit(err == nil)
	}
	tmux, gh := has("tmux"), has("gh")

	ec := envConf()
	if err := os.WriteFile(ec, nil, 0o644); err != nil {
		return fail(1, "detect: %v", err)
	}
	kv := [][2]string{
		{"current", current}, {"current_source", source},
		{"installed", strings.Join(installed, ",")}, {"spawnable", strings.Join(spawnable, ",")},
		{"tmux", tmux}, {"tmux_inside", bit(os.Getenv("TMUX") != "")},
		{"gh", gh}, {"glab", has("glab")}, {"git", has("git")},
	}
	for _, h := range spawnable {
		kv = append(kv, [2]string{"harness." + h + ".bin", bins[h]},
			[2]string{"harness." + h + ".exec", execRecipes[h]},
			[2]string{"harness." + h + ".resume", resumeRecipes[h]})
	}
	for _, p := range kv {
		if err := cfg.Set(ec, p[0], p[1]); err != nil {
			return fail(1, "detect: %v", err)
		}
	}
	if current == "" {
		current = "none"
	}
	fmt.Printf("DETECT current=%s installed=%s spawnable=%s tmux=%s gh=%s\n",
		current, strings.Join(installed, ","), strings.Join(spawnable, ","), tmux, gh)
	return 0
}

func procComm(pid int) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	if err != nil {
		return ""
	}
	return filepath.Base(strings.TrimSpace(string(b)))
}

func procPPID(pid int) int {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0
	}
	// fields after the ")" that closes comm: state ppid ...
	s := string(b)
	f := strings.Fields(s[strings.LastIndexByte(s, ')')+1:])
	if len(f) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(f[1])
	return n
}

// Reduce detected facts to a proposal + the fields to ask about.
//
//	plan -> PROPOSE critic=… researcher=… lane.default=… lane.strong=… autonomy=… tracker=… adapters=…
//	        ASK
//	          key=value (one per line)
//
// Writes $COORD_HOME/proposal.conf for apply. One spawnable harness forces the
// role map and lanes; no tmux forces adapters=none; no gh forces
// tracker=local; model is ALWAYS asked (default is only chosen if the user
// affirms it).
func cmdPlan(args []string) int {
	ec, config := envConf(), configPath()
	proposal := env("COORD_PROPOSAL", filepath.Join(coordHome(), "proposal.conf"))
	if err := os.MkdirAll(coordHome(), 0o755); err != nil {
		return fail(1, "plan: %v", err)
	}

	// already configured -> nothing to ask
	if isFile(config) {
		or := func(k, def string) string {
			if v, ok := cfg.Get(config, k); ok {
				return v
			}
			return def
		}
		fmt.Printf("PROPOSE critic=%s researcher=%s lane.default=%s lane.strong=%s autonomy=%s tracker=%s adapters=%s\n",
			or("critic.harness", "-"), or("researcher.harness", "-"), or("lane.default.harness", "-"),
			or("lane.strong.harness", "none"), or("autonomy", "-"), or("tracker", "-"), or("adapters", "-"))
		fmt.Println("ASK")
		return 0
	}

	var sp []string
	for _, h := range strings.Split(cfg.Value(ec, "spawnable"), ",") {
		if h != "" {
			sp = append(sp, h)
		}
	}
	if len(sp) == 0 {
		return fail(2, "plan: no spawnable harness in %s", ec)
	}
	current, def := cfg.Value(ec, "current"), sp[0]
	for _, h := range sp {
		if h == current {
			def = h
		}
	}
	strong, risky := "", "default"
	if len(sp) > 1 {
		for _, h := range sp {
			if h != def {
				strong, risky = h, "strong"
				break
			}
		}
	}

	if err := os.WriteFile(proposal, nil, 0o644); err != nil {
		return fail(1, "plan: %v", err)
	}
	kv := [][2]string{
		{"critic.harness", def}, {"critic.model", ""},
		{"researcher.harness", def}, {"researcher.model", ""},
		{"lane.default.harness", def}, {"lane.default.model", ""},
		{"routing.mechanical", "default"}, {"routing.risky", risky},
	}
	if strong != "" {
		kv = append(kv, [2]string{"lane.strong.harness", strong}, [2]string{"lane.strong.model", ""})
	}
	kv = append(kv, [2]string{"autonomy", "approve-merge"}, [2]string{"tracker", "local"}, [2]string{"adapters", "none"})
	for _, p := range kv {
		if err := cfg.Set(proposal, p[0], p[1]); err != nil {
			return fail(1, "plan: %v", err)
		}
	}

	// ASK block: concrete keys with proposed values. Empty model value means
	// "harness default" (the user must confirm).
	var ask []string
	if len(sp) > 1 {
		ask = append(ask, "critic.harness="+def, "researcher.harness="+def, "lane.default.harness="+def)
		if strong != "" {
			ask = append(ask, "lane.strong.harness="+strong)
		}
	}
	ask = append(ask, "critic.model=", "researcher.model=", "lane.default.model=")
	if strong != "" {
		ask = append(ask, "lane.strong.model=")
	}
	ask = append(ask, "autonomy=approve-merge")
	if cfg.Value(ec, "tmux") == "1" {
		ask = append(ask, "adapters=none")
	}
	if cfg.Value(ec, "gh") == "1" {
		ask = append(ask, "tracker=local")
	}

	fmt.Printf("PROPOSE critic=%s researcher=%s lane.default=%s lane.strong=%s autonomy=approve-merge tracker=local adapters=none\n",
		def, def, def, dashNone(strong))
	fmt.Println("ASK")
	for _, l := range ask {
		fmt.Printf("  %s\n", l)
	}
	return 0
}

func dashNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// Apply the user's answers over the proposal, validate, and write config.conf.
//
//	apply [--accept] [--answers "critic.model=… autonomy=auto-merge"] [--config PATH]
//	  -> OK config=<path>  |  FAIL <field>: <reason>
//
// Answers are literal space-separated `key=value` config keys; only those given
// override the proposal.
func cmdApply(args []string) int {
	var accept bool
	answers, config := "", configPath()
	if c := flags("apply", args, map[string]*string{"--answers": &answers, "--config": &config},
		map[string]*bool{"--accept": &accept}); c != 0 {
		return c
	}
	proposal := env("COORD_PROPOSAL", filepath.Join(coordHome(), "proposal.conf"))
	data, err := os.ReadFile(proposal)
	if err != nil {
		return fail(1, "FAIL proposal: run coord plan first")
	}
	tmp, err := os.CreateTemp(coordHome(), "config.")
	if err != nil {
		return fail(1, "FAIL config: %v", err)
	}
	tmp.Write(data)
	tmp.Close()
	defer os.Remove(tmp.Name())

	for _, kv := range strings.Fields(answers) {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			v = kv
		}
		if err := cfg.Set(tmp.Name(), k, v); err != nil {
			return fail(1, "FAIL %s: %v", k, err)
		}
	}

	// every referenced harness must resolve
	for _, k := range []string{"critic.harness", "researcher.harness", "lane.default.harness", "lane.strong.harness"} {
		h := cfg.Value(tmp.Name(), k)
		if h == "" {
			continue
		}
		bin := cfg.Value(envConf(), "harness."+h+".bin")
		if bin == "" {
			return fail(1, "FAIL %s: no harness.%s.bin in env.conf", k, h)
		}
		if strings.Contains(bin, "/") {
			if st, err := os.Stat(bin); err != nil || st.Mode()&0o111 == 0 {
				return fail(1, "FAIL %s: %s not executable", k, bin)
			}
		} else if _, err := exec.LookPath(bin); err != nil {
			return fail(1, "FAIL %s: %s not on PATH", k, bin)
		}
	}

	if err := os.MkdirAll(filepath.Dir(config), 0o755); err != nil {
		return fail(1, "FAIL config: %v", err)
	}
	if err := fsx.Move(tmp.Name(), config); err != nil {
		return fail(1, "FAIL config: %v", err)
	}
	fmt.Printf("OK config=%s\n", config)
	return 0
}
