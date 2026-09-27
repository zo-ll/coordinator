// Package playbook loads unit-kind playbooks and parses briefs.
//
// A playbook is a flat key=value header between `---` lines (never executed)
// and optional `## worker` / `## critic` body sections appended to those
// roles' prompts. A brief is a file of `FIELD:` sections, each starting at
// the beginning of a line and running to the next field.
package playbook

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Levels of evidence, weakest first.
var Levels = []string{"none", "typecheck", "tests", "live"}

// Rank is a level's position in Levels, or -1 if unknown.
func Rank(level string) int {
	for i, l := range Levels {
		if l == level {
			return i
		}
	}
	return -1
}

type Playbook struct {
	Kind    string
	Require []string      // worker brief fields
	Floor   string        // minimum evidence level for a pass
	Need    []string      // evidence flags a pass must carry
	Timebox time.Duration // default launch timebox
	Lane    string        // default worker lane
	Worker  string        // text appended to the worker prompt
	Critic  string        // text appended to the critic prompt
	Path    string
}

// Load finds kind.md in the first dir that has it: repo overrides first,
// then the shipped playbooks.
func Load(kind string, dirs ...string) (*Playbook, error) {
	if !regexp.MustCompile(`^[a-z][a-z0-9_-]*$`).MatchString(kind) {
		return nil, fmt.Errorf("invalid kind %q", kind)
	}
	for _, d := range dirs {
		p := filepath.Join(d, kind+".md")
		b, err := os.ReadFile(p)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		pb, err := Parse(b)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		if pb.Kind != kind {
			return nil, fmt.Errorf("%s: kind=%q, want %q", p, pb.Kind, kind)
		}
		pb.Path = p
		return pb, nil
	}
	return nil, fmt.Errorf("no playbook for kind %q", kind)
}

func list(v string) []string {
	var out []string
	for _, f := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' }) {
		out = append(out, f)
	}
	return out
}

// Parse reads a playbook file.
func Parse(b []byte) (*Playbook, error) {
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	if !strings.HasPrefix(s, "---\n") {
		return nil, fmt.Errorf("missing --- header")
	}
	head, body, ok := strings.Cut(s[4:], "\n---\n")
	if !ok {
		head, body, ok = strings.Cut(s[4:], "\n---")
		if !ok {
			return nil, fmt.Errorf("unterminated --- header")
		}
	}
	pb := &Playbook{Floor: "none", Lane: "default", Timebox: 30 * time.Minute}
	for _, line := range strings.Split(head, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		k, v, ok := strings.Cut(t, "=")
		if !ok {
			return nil, fmt.Errorf("header line %q is not key=value", t)
		}
		switch k {
		case "kind":
			pb.Kind = v
		case "brief.require":
			pb.Require = list(v)
		case "evidence.floor":
			if Rank(v) < 0 {
				return nil, fmt.Errorf("evidence.floor %q is not one of %s", v, strings.Join(Levels, ","))
			}
			pb.Floor = v
		case "evidence.require":
			pb.Need = list(v)
		case "timebox":
			d, err := time.ParseDuration(v)
			if err != nil || d <= 0 {
				return nil, fmt.Errorf("timebox %q is not a duration", v)
			}
			pb.Timebox = d
		case "lane":
			pb.Lane = v
		default:
			return nil, fmt.Errorf("unknown header key %q", k)
		}
	}
	if pb.Kind == "" {
		return nil, fmt.Errorf("kind is required")
	}
	pb.Worker, pb.Critic = section(body, "worker"), section(body, "critic")
	return pb, nil
}

// section returns the text under "## name" up to the next "## " heading.
func section(body, name string) string {
	var out []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "## ") {
			in = strings.EqualFold(strings.TrimSpace(line[3:]), name)
			continue
		}
		if in {
			out = append(out, line)
		}
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

// Brief is a parsed brief: its fields in order.
type Brief struct {
	Order  []string
	Fields map[string]string
}

var fieldRe = regexp.MustCompile(`^([A-Z][A-Z_]*):(.*)$`)

// ParseBrief splits a brief into FIELD: sections. Text before the first
// field is kept under the empty name.
func ParseBrief(b []byte) Brief {
	br := Brief{Fields: map[string]string{}}
	cur := ""
	var buf []string
	flush := func() {
		if cur != "" || strings.TrimSpace(strings.Join(buf, "")) != "" {
			if _, seen := br.Fields[cur]; !seen {
				br.Order = append(br.Order, cur)
			}
			br.Fields[cur] = strings.TrimSpace(strings.Join(buf, "\n"))
		}
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		if m := fieldRe.FindStringSubmatch(line); m != nil {
			flush()
			cur, buf = m[1], []string{strings.TrimSpace(m[2])}
			continue
		}
		buf = append(buf, line)
	}
	flush()
	return br
}

// Has reports whether the brief carries field (even if empty).
func (b Brief) Has(field string) bool {
	_, ok := b.Fields[field]
	return ok
}

// Missing returns the required fields the brief lacks.
func (b Brief) Missing(required []string) []string {
	var out []string
	for _, f := range required {
		if !b.Has(f) {
			out = append(out, f)
		}
	}
	return out
}

// Verify returns the VERIFY section's commands: lines starting with "$ ".
func (b Brief) Verify() []string {
	var out []string
	for _, line := range strings.Split(b.Fields["VERIFY"], "\n") {
		if c, ok := strings.CutPrefix(strings.TrimSpace(line), "$ "); ok && strings.TrimSpace(c) != "" {
			out = append(out, strings.TrimSpace(c))
		}
	}
	return out
}

// Timebox is the brief's TIMEBOX (first word, a duration), or def.
func (b Brief) Timebox(def time.Duration) (time.Duration, error) {
	v := strings.Fields(b.Fields["TIMEBOX"])
	if len(v) == 0 {
		return def, nil
	}
	d, err := time.ParseDuration(v[0])
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("TIMEBOX %q is not a duration (e.g. 45m)", v[0])
	}
	return d, nil
}

// Section renders one field back as "FIELD: text".
func (b Brief) Section(field string) string {
	return field + ": " + b.Fields[field]
}
