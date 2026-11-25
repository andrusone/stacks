package installer

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// PreflightEnv is what Preflight checks: the user id, the os-release file and the lock path.
type PreflightEnv struct {
	UID           int
	OSReleasePath string
	LockPath      string
}

// Preflight checks SI-FR-10 in order and returns the first problem as one plain line.
// On success the lock at env.LockPath is held (its file holds this process id) until Release.
func Preflight(env PreflightEnv) error {
	if env.UID == 0 {
		return errors.New("error: run this as your normal user, not root; it calls sudo itself")
	}
	if err := checkOS(env.OSReleasePath); err != nil {
		return err
	}
	return takeLock(env.LockPath)
}

// Release removes the lock Preflight took.
func Release(lockPath string) {
	_ = os.Remove(lockPath)
}

// checkOS reads KEY=value lines from an os-release file and wants Ubuntu 26.04.
func checkOS(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("error: cannot read %s: %v", path, err)
	}
	defer f.Close()
	vals := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, val, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		vals[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(val), `"'`)
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("error: cannot read %s: %v", path, err)
	}
	if vals["ID"] != "ubuntu" || vals["VERSION_ID"] != "26.04" {
		return fmt.Errorf("error: this runs only on Ubuntu 26.04 (found %s %s)", vals["ID"], vals["VERSION_ID"])
	}
	return nil
}

// takeLock creates the lock file exclusively and writes this process id into it.
// A lock whose process is gone is taken over; a live one stops the run.
func takeLock(path string) error {
	for attempt := 0; attempt < 2; attempt++ {
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err == nil {
			_, werr := fmt.Fprintf(f, "%d\n", os.Getpid())
			cerr := f.Close()
			if werr != nil || cerr != nil {
				_ = os.Remove(path)
				return fmt.Errorf("error: cannot write the lock %s", path)
			}
			return nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("error: cannot create the lock %s: %v", path, err)
		}
		if pid, ok := lockPid(path); ok && processAlive(pid) {
			return fmt.Errorf("error: another setup-stacks run is in progress (pid %d)", pid)
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("error: cannot remove the stale lock %s: %v", path, err)
		}
	}
	return fmt.Errorf("error: cannot take the lock %s", path)
}

// lockPid reads the process id a lock file holds; ok is false when it holds none.
func lockPid(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

// processAlive asks the kernel whether pid exists. EPERM means it exists but is not ours.
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
