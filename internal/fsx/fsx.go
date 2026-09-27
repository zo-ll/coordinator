// Package fsx holds the file primitives every store relies on: atomic
// replace, cross-device move, and an exclusive advisory lock.
package fsx

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// WriteAtomic replaces path with data via a temp file in the same directory.
func WriteAtomic(path string, data []byte) error {
	dir, base := filepath.Split(path)
	if dir == "" {
		dir = "."
	}
	f, err := os.CreateTemp(dir, base+".")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// Move renames src to dst, copying when they are on different filesystems.
func Move(src, dst string) error {
	err := os.Rename(src, dst)
	if err == nil || !errors.Is(err, syscall.EXDEV) {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	dir, base := filepath.Split(dst)
	if dir == "" {
		dir = "."
	}
	out, err := os.CreateTemp(dir, base+".")
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(out.Name())
		return err
	}
	out.Chmod(st.Mode().Perm())
	if err := out.Close(); err != nil {
		os.Remove(out.Name())
		return err
	}
	if err := os.Rename(out.Name(), dst); err != nil {
		os.Remove(out.Name())
		return err
	}
	return os.Remove(src)
}

// Lock takes an exclusive flock on path (created if absent). Close the
// returned file to release it.
func Lock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// TryLock is Lock without waiting: ok is false when another holder exists.
func TryLock(path string) (f *os.File, ok bool, err error) {
	f, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return f, true, nil
}
