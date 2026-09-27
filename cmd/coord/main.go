// Command coord is the coordinator engine. Each subcommand implements one v1
// script contract (scripts/<verb>.sh is a shim that execs `coord <verb>`):
// the same arguments, the same one-line output, the same files.
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
	"cfg":      cmdCfg,
	"detect":   cmdDetect,
	"finish":   cmdFinish,
	"hygiene":  cmdHygiene,
	"invoke":   cmdInvoke,
	"merge":    cmdMerge,
	"plan":     cmdPlan,
	"queue":    cmdQueue,
	"relay":    cmdRelay,
	"spawn":    cmdSpawn,
	"start":    cmdStart,
	"state":    cmdState,
	"status":   cmdStatus,
	"worktree": cmdWorktree,
}

func main() {
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

func cwd() string {
	d, err := os.Getwd()
	if err != nil {
		return "."
	}
	return d
}

func coordRoot() string { return env("COORD_ROOT", "/tmp/coordinator") }
func coordHome() string { return env("COORD_HOME", filepath.Join(os.Getenv("HOME"), ".coordinator")) }
func envConf() string   { return env("COORD_ENV_CONF", filepath.Join(coordHome(), "env.conf")) }
func configPath() string {
	return env("COORD_CONFIG", filepath.Join(cwd(), ".coordinator", "config.conf"))
}
func ledgerPath() string {
	return env("COORD_LEDGER", filepath.Join(cwd(), ".coordinator", "ledger.tsv"))
}
func repoDir() string { return env("COORD_REPO", cwd()) }

// scriptsDir is where the shims live: set by the shim, else next to bin/.
func scriptsDir() string {
	if d := os.Getenv("COORD_SCRIPTS"); d != "" {
		return d
	}
	exe, err := os.Executable()
	if err != nil {
		return "scripts"
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return filepath.Join(filepath.Dir(filepath.Dir(exe)), "scripts")
}

// flags parses "--name value" and "--name" (bool) arguments; anything else is
// an unknown-arg error in the script's own wording.
func flags(prog string, args []string, vals map[string]*string, bools map[string]*bool) int {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if b, ok := bools[a]; ok {
			*b = true
			continue
		}
		if v, ok := vals[a]; ok {
			if i+1 >= len(args) {
				return fail(2, "%s: %s needs a value", prog, a)
			}
			*v = args[i+1]
			i++
			continue
		}
		return fail(2, "%s: unknown arg: %s", prog, a)
	}
	return 0
}

func arg(args []string, i int) string {
	if i < len(args) {
		return args[i]
	}
	return ""
}

// git runs git and returns stdout without trailing newlines; stderr is dropped.
func git(args ...string) (string, error) {
	out, err := gitRaw(args...)
	return strings.TrimRight(string(out), "\n"), err
}

func gitRaw(args ...string) ([]byte, error) {
	var out bytes.Buffer
	c := exec.Command("git", args...)
	c.Stdout = &out
	err := c.Run()
	return out.Bytes(), err
}

// gitLoud runs git with its output on our stderr (stdout stays one line).
func gitLoud(args ...string) error {
	c := exec.Command("git", args...)
	c.Stdout, c.Stderr = os.Stderr, os.Stderr
	return c.Run()
}

func alive(pid string) bool {
	if pid == "" || pid == "-" {
		return false
	}
	var n int
	if _, err := fmt.Sscanf(pid, "%d", &n); err != nil || n <= 0 {
		return false
	}
	return syscall.Kill(n, 0) == nil
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
