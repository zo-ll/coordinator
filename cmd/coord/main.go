// Command coord is the coordinator engine: one binary, one subcommand per
// protocol step, one line of output per result. See SPEC-v2.md.
package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

var commands = map[string]func([]string) int{
	"apply":    cmdApply,
	"approve":  cmdDecide("approved"),
	"block":    cmdDecide("blocked"),
	"cfg":      cmdCfg,
	"detect":   cmdDetect,
	"dispatch": cmdDispatch,
	"done":     cmdDone,
	"drop":     cmdDecide("dropped"),
	"finish":   cmdFinish,
	"log":      cmdLog,
	"merge":    cmdMerge,
	"msg":      cmdDecide("msg"),
	"plan":     cmdPlan,
	"reject":   cmdDecide("rejected"),
	"relay":    cmdRelay,
	"render":   cmdRender,
	"reopen":   cmdDecide("reopened"),
	"research": cmdResearch,
	"start":    cmdStart,
	"status":   cmdStatus,
	"unit":     cmdUnit,
}

func main() {
	rebuildIfStale()
	if len(os.Args) < 2 {
		os.Exit(fail(2, "usage: coord <%s> ...", verbs()))
	}
	cmd, ok := commands[os.Args[1]]
	if !ok {
		os.Exit(fail(2, "coord: unknown command %q (want one of: %s)", os.Args[1], verbs()))
	}
	os.Exit(cmd(os.Args[2:]))
}

func verbs() string {
	var vs []string
	for v := range commands {
		vs = append(vs, v)
	}
	sort.Strings(vs)
	return strings.Join(vs, "|")
}

// fail prints one line to stderr and returns code, for `return fail(...)`.
func fail(code int, format string, a ...any) int {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	return code
}

// env is ${name:-def}: an empty variable counts as unset.
func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

// flags parses "--name value", repeatable "--name value" (multi), and
// "--name" (bool); anything else is an unknown-arg error.
type flagSet struct {
	vals  map[string]*string
	multi map[string]*[]string
	bools map[string]*bool
}

func (fs flagSet) parse(prog string, args []string) int {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if b, ok := fs.bools[a]; ok {
			*b = true
			continue
		}
		v, one := fs.vals[a]
		m, many := fs.multi[a]
		if !one && !many {
			return fail(2, "%s: unknown arg: %s", prog, a)
		}
		if i+1 >= len(args) {
			return fail(2, "%s: %s needs a value", prog, a)
		}
		if one {
			*v = args[i+1]
		} else {
			*m = append(*m, args[i+1])
		}
		i++
	}
	return 0
}

func flags(prog string, args []string, vals map[string]*string, bools map[string]*bool) int {
	return flagSet{vals: vals, bools: bools}.parse(prog, args)
}

func arg(args []string, i int) string {
	if i < len(args) {
		return args[i]
	}
	return ""
}

// git runs git and returns stdout without trailing newlines; stderr is dropped.
func git(args ...string) (string, error) {
	out, err := gitRaw(nil, args...)
	return strings.TrimRight(string(out), "\n"), err
}

func gitRaw(extraEnv []string, args ...string) ([]byte, error) {
	var out bytes.Buffer
	c := exec.Command("git", args...)
	c.Stdout = &out
	if extraEnv != nil {
		c.Env = append(os.Environ(), extraEnv...)
	}
	err := c.Run()
	return out.Bytes(), err
}

// gitLoud runs git with its output on our stderr (stdout stays one line).
func gitLoud(args ...string) error {
	c := exec.Command("git", args...)
	c.Stdout, c.Stderr = os.Stderr, os.Stderr
	return c.Run()
}

func alive(pid int) bool { return pid > 0 && syscall.Kill(pid, 0) == nil }

// killGroup signals a launch's process group (launches run under setsid),
// falling back to the process itself.
func killGroup(pid int, sig syscall.Signal) {
	if pid <= 0 {
		return
	}
	if syscall.Kill(-pid, sig) != nil {
		syscall.Kill(pid, sig)
	}
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

func nonEmpty(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Size() > 0
}

func readTrim(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(b), "\n")
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func bit(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func hasLine(s, want string) bool {
	for _, l := range strings.Split(s, "\n") {
		if l == want {
			return true
		}
	}
	return false
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

// self is this binary's resolved path, for finish contracts and the relay.
func self() string {
	exe, err := os.Executable()
	if err != nil {
		return "coord"
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		return r
	}
	return exe
}
