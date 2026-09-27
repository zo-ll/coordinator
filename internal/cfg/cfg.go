// Package cfg reads and writes flat key=value files. Values are literal and
// never evaluated, so a committed value cannot execute. Callers never see the
// on-disk format.
package cfg

import (
	"os"
	"strings"

	"github.com/zo-ll/coordinator/internal/fsx"
)

func lines(file string) ([]string, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	return strings.Split(strings.TrimSuffix(string(b), "\n"), "\n"), nil
}

func write(file string, ls []string) error {
	var b strings.Builder
	for _, l := range ls {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return fsx.WriteAtomic(file, []byte(b.String()))
}

// Get returns the value of key; the last assignment wins. ok is false when
// the file or the key is absent.
func Get(file, key string) (v string, ok bool) {
	ls, err := lines(file)
	if err != nil {
		return "", false
	}
	for _, l := range ls {
		if strings.HasPrefix(l, key+"=") {
			v, ok = l[len(key)+1:], true
		}
	}
	return v, ok
}

// Value is Get with absent treated as empty.
func Value(file, key string) string {
	v, _ := Get(file, key)
	return v
}

// Set writes key=value in place of the first assignment (dropping any later
// ones), or appends it. The file is created if absent.
func Set(file, key, value string) error {
	ls, err := lines(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	out := make([]string, 0, len(ls)+1)
	done := false
	for _, l := range ls {
		if strings.HasPrefix(l, key+"=") {
			if !done {
				out = append(out, key+"="+value)
				done = true
			}
			continue
		}
		out = append(out, l)
	}
	if !done {
		out = append(out, key+"="+value)
	}
	return write(file, out)
}

// Unset removes every assignment of key. A missing file is not an error.
func Unset(file, key string) error {
	ls, err := lines(file)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	out := ls[:0]
	for _, l := range ls {
		if !strings.HasPrefix(l, key+"=") {
			out = append(out, l)
		}
	}
	return write(file, out)
}

// Keys lists keys in file order, skipping comments and blank lines, filtered
// by prefix when it is non-empty.
func Keys(file, prefix string) []string {
	ls, _ := lines(file)
	var keys []string
	for _, l := range ls {
		t := strings.TrimLeft(l, " \t")
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		k, _, _ := strings.Cut(l, "=")
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	return keys
}
