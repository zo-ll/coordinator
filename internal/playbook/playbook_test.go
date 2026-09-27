package playbook

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const bugfix = `---
kind=bugfix
brief.require=GOAL,SCOPE,REPRO,ACCEPTANCE,VERIFY
evidence.floor=tests
evidence.require=red-green
timebox=45m
lane=default
---
## worker
Reproduce first.

## critic
Run the new test against the base commit.
`

func TestParse(t *testing.T) {
	pb, err := Parse([]byte(bugfix))
	if err != nil {
		t.Fatal(err)
	}
	if pb.Kind != "bugfix" || pb.Floor != "tests" || pb.Timebox != 45*time.Minute || pb.Lane != "default" {
		t.Fatalf("header: %+v", pb)
	}
	if !reflect.DeepEqual(pb.Require, []string{"GOAL", "SCOPE", "REPRO", "ACCEPTANCE", "VERIFY"}) || !reflect.DeepEqual(pb.Need, []string{"red-green"}) {
		t.Fatalf("lists: %v %v", pb.Require, pb.Need)
	}
	if pb.Worker != "Reproduce first." || pb.Critic != "Run the new test against the base commit." {
		t.Fatalf("sections: %q %q", pb.Worker, pb.Critic)
	}
}

func TestParseRefusals(t *testing.T) {
	for name, src := range map[string]string{
		"no header":     "kind=x\n",
		"bad floor":     "---\nkind=x\nevidence.floor=vibes\n---\n",
		"bad timebox":   "---\nkind=x\ntimebox=soon\n---\n",
		"unknown key":   "---\nkind=x\ncolor=red\n---\n",
		"not key=value": "---\nkind=x\njust words\n---\n",
		"no kind":       "---\nlane=default\n---\n",
	} {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("%s: parsed", name)
		}
	}
}

func TestLoadOverride(t *testing.T) {
	repo, shipped := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(shipped, "chore.md"), []byte("---\nkind=chore\ntimebox=20m\n---\n"), 0o644)
	pb, err := Load("chore", repo, shipped)
	if err != nil || pb.Timebox != 20*time.Minute {
		t.Fatalf("shipped: %+v %v", pb, err)
	}
	os.WriteFile(filepath.Join(repo, "chore.md"), []byte("---\nkind=chore\ntimebox=5m\n---\n"), 0o644)
	if pb, _ = Load("chore", repo, shipped); pb.Timebox != 5*time.Minute {
		t.Fatalf("override not used: %v", pb.Timebox)
	}
	if _, err := Load("ghost", repo, shipped); err == nil || !strings.Contains(err.Error(), "no playbook") {
		t.Fatalf("unknown kind: %v", err)
	}
	if _, err := Load("../x", repo); err == nil {
		t.Fatal("path traversal kind accepted")
	}
}

func TestBrief(t *testing.T) {
	b := ParseBrief([]byte(`Fix the drift.
GOAL: scroll stops drifting
SCOPE: ui/scroll.go only
CONTEXT: see #12; the old fix was reverted
VERIFY:
  $ go test ./ui/...
  run it twice; flaky under -race
  $ go vet ./...
TIMEBOX: 20m
`))
	if got := b.Missing([]string{"GOAL", "SCOPE", "ACCEPTANCE", "VERIFY"}); !reflect.DeepEqual(got, []string{"ACCEPTANCE"}) {
		t.Fatalf("missing %v", got)
	}
	if got := b.Verify(); !reflect.DeepEqual(got, []string{"go test ./ui/...", "go vet ./..."}) {
		t.Fatalf("verify %v", got)
	}
	if d, err := b.Timebox(time.Hour); err != nil || d != 20*time.Minute {
		t.Fatalf("timebox %v %v", d, err)
	}
	if b.Fields["CONTEXT"] != "see #12; the old fix was reverted" || b.Fields[""] != "Fix the drift." {
		t.Fatalf("fields %q", b.Fields)
	}
	if _, err := ParseBrief([]byte("TIMEBOX: whenever\n")).Timebox(time.Hour); err == nil {
		t.Fatal("bad TIMEBOX accepted")
	}
	if Rank("tests") <= Rank("typecheck") || Rank("bogus") != -1 {
		t.Fatal("level ranks")
	}
}
