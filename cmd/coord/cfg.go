package main

import (
	"fmt"

	"github.com/zo-ll/coordinator/internal/cfg"
)

// cfg get <file> <key>          -> value (exit 1 if absent)
// cfg set <file> <key> [value]  (empty value allowed)
// cfg unset <file> <key>
// cfg keys <file> [prefix]
func cmdCfg(args []string) int {
	sub, file, key := arg(args, 0), arg(args, 1), arg(args, 2)
	switch sub {
	case "get", "set", "unset":
		if key == "" {
			return fail(1, "coord cfg: key is required")
		}
	}
	switch sub {
	case "get":
		v, ok := cfg.Get(file, key)
		if !ok {
			return 1
		}
		fmt.Println(v)
	case "set":
		if err := cfg.Set(file, key, arg(args, 3)); err != nil {
			return fail(1, "coord cfg: %v", err)
		}
	case "unset":
		if err := cfg.Unset(file, key); err != nil {
			return fail(1, "coord cfg: %v", err)
		}
	case "keys":
		for _, k := range cfg.Keys(file, key) {
			fmt.Println(k)
		}
	default:
		return fail(2, "usage: coord cfg get|set|unset|keys <file> ...")
	}
	return 0
}
