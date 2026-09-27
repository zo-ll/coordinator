package main

import (
	"fmt"
	"strings"
	"syscall"

	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
)

// User decisions and unit control, each one event:
//
//	approve <id> ["<note>"]         -> APPROVED <id>   (passed -> approved)
//	reject <id> ["<note>"]          -> REJECTED <id>   (passed|approved -> handback)
//	msg <id|-> "<text>"             -> MSG <id|->
//	block <id> --reason "<r>"       -> BLOCKED <id>    (stops its live launch)
//	reopen <id> --reason "<r>"      -> REOPENED <id>   (blocked -> todo)
//	drop <id> --reason "<r>"        -> DROPPED <id>    (stops its live launch)
func cmdDecide(typ string) func([]string) int {
	verb := map[string]string{"approved": "approve", "rejected": "reject", "msg": "msg",
		"blocked": "block", "reopened": "reopen", "dropped": "drop"}[typ]
	return func(args []string) int {
		id := arg(args, 0)
		if id == "" || strings.HasPrefix(id, "--") {
			return fail(2, "%s: <id> is required", verb)
		}
		e := events.Event{Type: typ, Unit: id}
		switch typ {
		case "approved", "rejected", "msg":
			e.Text = strings.Join(args[1:], " ")
			if typ == "msg" {
				if e.Text == "" {
					return fail(2, "msg: <text> is required")
				}
				if id == "-" {
					e.Unit = ""
				}
			}
		default:
			if c := flags(verb, args[1:], map[string]*string{"--reason": &e.Reason}, nil); c != 0 {
				return c
			}
			if e.Reason == "" {
				return fail(2, "%s: --reason is required", verb)
			}
			e.By = "user"
		}
		var stop int
		_, err := commit(func(r *model.Run) ([]events.Event, error) {
			if u := r.Units[id]; u != nil && u.Owes != "" && (typ == "blocked" || typ == "dropped") {
				stop = u.PID
			}
			return []events.Event{e}, nil
		})
		if err != nil {
			return refused(err)
		}
		killGroup(stop, syscall.SIGTERM)
		fmt.Printf("%s %s\n", strings.ToUpper(typ), dash(e.Unit))
		return 0
	}
}
