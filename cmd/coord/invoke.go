package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/zo-ll/coordinator/internal/cfg"
)

// buildArgv expands the harness's env.conf exec recipe, a '|'-separated argv
// template:
//
//	__CWD__     -> the role's working directory
//	__PROMPT__  -> role preamble (agents/<role>.md, or $COORD_AGENTS) + brief
//	__MODEL__   -> the model; if empty, this token AND the one before it (the
//	               model flag) are dropped
func buildArgv(harness, role, prompt, dir, model string) ([]string, error) {
	brief, err := os.ReadFile(prompt)
	if err != nil {
		return nil, fmt.Errorf("invoke: prompt file not readable: %s", prompt)
	}
	recipe, ok := cfg.Get(envConf(), "harness."+harness+".exec")
	if !ok {
		return nil, fmt.Errorf("invoke: no exec recipe for harness '%s' in %s", harness, envConf())
	}
	text := strings.TrimRight(string(brief), "\n")
	agents := env("COORD_AGENTS", filepath.Join(skillRoot(), "agents"))
	if pre, err := os.ReadFile(filepath.Join(agents, role+".md")); err == nil {
		text = strings.TrimRight(string(pre), "\n") + "\n\n" + text
	}

	toks := strings.Split(recipe, "|")
	if len(toks) > 0 && toks[len(toks)-1] == "" {
		toks = toks[:len(toks)-1]
	}
	var out []string
	for _, t := range toks {
		switch t {
		case "__CWD__":
			out = append(out, dir)
		case "__PROMPT__":
			out = append(out, text)
		case "__MODEL__":
			if model != "" {
				out = append(out, model)
			} else if len(out) > 0 {
				out = out[:len(out)-1]
			}
		default:
			out = append(out, t)
		}
	}
	return out, nil
}
