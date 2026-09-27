package model

import (
	"errors"
	"strings"
	"testing"

	"github.com/zo-ll/coordinator/internal/events"
)

type ev = events.Event

func add(id string, deps ...string) ev {
	return ev{Type: "unit_added", Unit: id, Kind: "feature", Deps: deps}
}
func disp(id, role string, round, pid int) ev {
	return ev{Type: "dispatched", Unit: id, Role: role, Round: round, Slug: Slug(id, round, role), PID: pid}
}
func fin(id, role string, round int, result string) ev {
	return ev{Type: "finished", Unit: id, Role: role, Slug: Slug(id, round, role), Result: result}
}
func died(id, role string, round, pid int) ev {
	return ev{Type: "died", Slug: Slug(id, round, role), PID: pid, Reason: "exited"}
}
func on(t, id string) ev { return ev{Type: t, Unit: id} }

// prefixes that bring unit "u" to a given state
var (
	toTodo      = []ev{add("u")}
	toWorking   = append(toTodo, disp("u", "worker", 1, 10))
	toBuilt     = append(toWorking, fin("u", "worker", 1, "done"))
	toReviewing = append(toBuilt, disp("u", "critic", 1, 11))
	toPassed    = append(toReviewing, fin("u", "critic", 1, "pass"))
	toHandback  = append(toReviewing, fin("u", "critic", 1, "handback"))
	toStalled   = append(toWorking, died("u", "worker", 1, 10))
	toApproved  = append(toPassed, on("approved", "u"))
	toBlocked   = append(toTodo, on("blocked", "u"))
)

func clone(evs []ev) []ev { return append([]ev(nil), evs...) }

func TestTransitions(t *testing.T) {
	cases := []struct {
		name   string
		prefix []ev
		e      ev
		want   State  // state after, when legal
		refuse string // substring of the refusal, when illegal
	}{
		// legal moves, one per row of the SPEC-v2 table
		{"add", nil, add("u"), Todo, ""},
		{"todo+worker", toTodo, disp("u", "worker", 1, 10), Working, ""},
		{"handback+worker", toHandback, disp("u", "worker", 2, 12), Working, ""},
		{"worker done", toWorking, fin("u", "worker", 1, "done"), Built, ""},
		{"worker partial", toWorking, fin("u", "worker", 1, "partial"), Handback, ""},
		{"built+critic", toBuilt, disp("u", "critic", 1, 11), Reviewing, ""},
		{"critic pass", toReviewing, fin("u", "critic", 1, "pass"), Passed, ""},
		{"critic handback", toReviewing, fin("u", "critic", 1, "handback"), Handback, ""},
		{"converted", toPassed, on("converted", "u"), Handback, ""},
		{"worker died", toWorking, died("u", "worker", 1, 10), Stalled, ""},
		{"critic died", toReviewing, died("u", "critic", 1, 11), Stalled, ""},
		{"stalled+worker same round", toStalled, disp("u", "worker", 1, 13), Working, ""},
		{"approve", toPassed, on("approved", "u"), Approved, ""},
		{"reject", toPassed, on("rejected", "u"), Handback, ""},
		{"verify_failed approved", toApproved, on("verify_failed", "u"), Handback, ""},
		{"verify_failed passed", toPassed, on("verify_failed", "u"), Handback, ""},
		{"merge approved", toApproved, on("merged", "u"), Merged, ""},
		{"merge passed (auto-merge)", toPassed, on("merged", "u"), Merged, ""},
		{"block working", toWorking, on("blocked", "u"), Blocked, ""},
		{"reopen", toBlocked, on("reopened", "u"), Todo, ""},
		{"drop blocked", toBlocked, on("dropped", "u"), Dropped, ""},

		// refused moves
		{"dup id", toTodo, add("u"), "", "already exists"},
		{"bad id", nil, add("u.1"), "", "invalid id"},
		{"unknown dep", nil, add("u", "ghost"), "", "unknown dep"},
		{"worker round skip", toTodo, disp("u", "worker", 2, 10), "", "round 2, want 1"},
		{"coordinator slug", toTodo, ev{Type: "dispatched", Unit: "u", Role: "worker", Round: 1, Slug: "u", PID: 1}, "", "want \"u.r1.worker\""},
		{"critic before built", toWorking, disp("u", "critic", 1, 11), "", "cannot dispatch a critic from working"},
		{"worker while working", toWorking, disp("u", "worker", 2, 11), "", "cannot dispatch a worker from working"},
		{"stalled other role", toStalled, disp("u", "critic", 1, 11), "", "cannot dispatch a critic from stalled"},
		{"stale slug", toHandback, fin("u", "worker", 1, "done"), "", "already"},
		{"unowed slug", toWorking, fin("u", "critic", 1, "pass"), "", "not owed"},
		{"worker pass", toWorking, fin("u", "worker", 1, "pass"), "", "worker result \"pass\""},
		{"died wrong pid", toWorking, died("u", "worker", 1, 99), "", "no live launch"},
		{"approve built", toBuilt, on("approved", "u"), "", "cannot approve from built"},
		{"merge reviewing", toReviewing, on("merged", "u"), "", "cannot merge from reviewing"},
		{"reopen todo", toTodo, on("reopened", "u"), "", "cannot reopen from todo"},
		{"block blocked", toBlocked, on("blocked", "u"), "", "not allowed from blocked"},
		{"drop merged", append(clone(toApproved), on("merged", "u")), on("dropped", "u"), "", "not allowed from merged"},
		{"converted working", toWorking, on("converted", "u"), "", "cannot convert"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := New()
			for i, p := range clone(c.prefix) {
				if err := r.Apply(p); err != nil {
					t.Fatalf("prefix event %d (%s) refused: %v", i, p.Type, err)
				}
			}
			err := r.Apply(c.e)
			if c.refuse != "" {
				if err == nil {
					t.Fatalf("applied, want refusal containing %q", c.refuse)
				}
				if !strings.Contains(err.Error(), c.refuse) && !(c.refuse == "already" && errors.Is(err, ErrDup)) {
					t.Fatalf("refused with %q, want %q", err, c.refuse)
				}
				return
			}
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			if got := r.Units["u"].State; got != c.want {
				t.Fatalf("state %s, want %s", got, c.want)
			}
		})
	}
}

func TestReadyNeedsTerminalDeps(t *testing.T) {
	r := Fold([]ev{add("a"), add("b", "a")})
	if !r.Ready(r.Units["a"]) || r.Ready(r.Units["b"]) {
		t.Fatal("a should be ready, b not")
	}
	if err := r.Apply(disp("b", "worker", 1, 1)); err == nil || !strings.Contains(err.Error(), "not ready") {
		t.Fatalf("dispatching b before a merged: %v", err)
	}
	r.Apply(on("dropped", "a"))
	if !r.Ready(r.Units["b"]) {
		t.Fatal("b should be ready once a is dropped")
	}
}

func TestRetryCap(t *testing.T) {
	r := Fold(clone(toStalled))
	if err := r.Apply(disp("u", "worker", 1, 20)); err != nil {
		t.Fatal(err)
	}
	if err := r.Apply(died("u", "worker", 1, 20)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.NextRound(r.Units["u"], "worker"); err == nil || !strings.Contains(err.Error(), "died 2 times") {
		t.Fatalf("third launch in a round: %v", err)
	}
}

func TestRoundsAdvance(t *testing.T) {
	r := Fold(clone(toHandback))
	r.Apply(disp("u", "worker", 2, 12))
	if u := r.Units["u"]; u.Round != 2 || u.Owes != "u.r2.worker" {
		t.Fatalf("round %d owes %q", u.Round, u.Owes)
	}
	// reopen after a block continues at the next unused round
	r = Fold(append(clone(toHandback), on("blocked", "u"), on("reopened", "u")))
	if n, err := r.NextRound(r.Units["u"], "worker"); err != nil || n != 2 {
		t.Fatalf("round after reopen: %d %v", n, err)
	}
}

func TestDuplicateFinish(t *testing.T) {
	r := Fold(clone(toBuilt))
	if err := r.Apply(fin("u", "worker", 1, "done")); !errors.Is(err, ErrDup) {
		t.Fatalf("want ErrDup, got %v", err)
	}
}

func TestDelivery(t *testing.T) {
	log := clone(toBuilt)
	for i := range log {
		log[i].Seq = i + 1
	}
	r := Fold(log)
	w := r.Undelivered()
	if len(w) != 1 || w[0].Type != "finished" {
		t.Fatalf("undelivered %+v", w)
	}
	s := w[0].Seq
	if err := r.Apply(ev{Seq: 10, Type: "claimed", Seqs: []int{s}, Batch: "b"}); err != nil {
		t.Fatal(err)
	}
	if len(r.Undelivered()) != 0 || len(r.InFlight()) != 1 {
		t.Fatal("claimed event still undelivered")
	}
	if err := r.Apply(ev{Seq: 11, Type: "claimed", Seqs: []int{s}}); err == nil {
		t.Fatal("double claim allowed")
	}
	r.Apply(ev{Seq: 12, Type: "nacked", Seqs: []int{s}})
	if len(r.Undelivered()) != 1 {
		t.Fatal("nack did not return the event")
	}
	r.Apply(ev{Seq: 13, Type: "claimed", Seqs: []int{s}})
	r.Apply(ev{Seq: 14, Type: "acked", Seqs: []int{s}})
	if len(r.Undelivered())+len(r.InFlight()) != 0 {
		t.Fatal("acked event still pending")
	}
	if !Wake(ev{Type: "blocked", By: "engine"}) || Wake(ev{Type: "blocked"}) {
		t.Fatal("only engine blocks wake the coordinator")
	}
}
