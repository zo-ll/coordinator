package main

import (
	"fmt"
	"strings"

	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
	"github.com/zo-ll/coordinator/internal/playbook"
)

// unit add <id> --kind <k> --goal "<g>" [--deps a,b] [--risk <r>]  -> ADDED <id> kind=<k>
// unit next                                                     -> ready ids, space-separated
func cmdUnit(args []string) int {
	switch arg(args, 0) {
	case "add":
		id := arg(args, 1)
		if id == "" || strings.HasPrefix(id, "--") {
			return fail(2, "unit add: <id> is required")
		}
		var kind, goal, deps, risk string
		if c := flags("unit add", args[2:], map[string]*string{
			"--kind": &kind, "--goal": &goal, "--deps": &deps, "--risk": &risk,
		}, nil); c != 0 {
			return c
		}
		if kind == "" || goal == "" {
			return fail(2, "unit add: --kind and --goal are required")
		}
		if _, err := playbook.Load(kind, playbookDirs()...); err != nil {
			return refuse(id, "unit_added", "%v", err)
		}
		var ds []string
		for _, d := range strings.Split(deps, ",") {
			if d = strings.TrimSpace(d); d != "" {
				ds = append(ds, d)
			}
		}
		_, err := commit(func(*model.Run) ([]events.Event, error) {
			return []events.Event{{Type: "unit_added", Unit: id, Kind: kind, Goal: goal, Deps: ds, Risk: risk}}, nil
		})
		if err != nil {
			return refused(err)
		}
		fmt.Printf("ADDED %s kind=%s\n", id, kind)

	case "next":
		r := load()
		var ids []string
		for _, id := range r.Order {
			if r.Ready(r.Units[id]) {
				ids = append(ids, id)
			}
		}
		if len(ids) > 0 {
			fmt.Println(strings.Join(ids, " "))
		}

	default:
		return fail(2, "usage: coord unit add|next ...")
	}
	return 0
}
