package installer

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"stacks/internal/record"
	"stacks/internal/stack"
)

// folders are the four folders every stack has under its own name in SvrDir (SI-FR-07).
var folders = []string{"data", "logs", "config", "backup"}

// CheckConfig is what Check reads (SI-FR-08). UnitState answers, for a unit
// name, whether it is enabled and whether it is active; the caller asks
// systemd and tests fake it.
type CheckConfig struct {
	SvrDir, RecordsDir string
	UnitState          func(unit string) (enabled, active bool)
}

// CheckResult is what Check reports: one line per installed stack, then any
// unexpected folder. NotOK is true only when a stack is not ok.
type CheckResult struct {
	Lines []string
	NotOK bool
}

// Check reports what is installed (SI-FR-08). It changes nothing: the only
// thing it runs is a stack's check step, in the stack's folder. A non-empty
// only limits the stack lines to that one name.
func Check(cfg CheckConfig, stacks []stack.Stack, only string) CheckResult {
	recs, err := record.List(cfg.RecordsDir)
	if err != nil {
		return CheckResult{Lines: []string{fmt.Sprintf("error: cannot read the records in %s: %v", cfg.RecordsDir, err)}}
	}
	if only != "" {
		recs = keepNamed(recs, only)
		if len(recs) == 0 {
			return CheckResult{Lines: []string{only + " is not installed here"}}
		}
	} else if len(recs) == 0 {
		return CheckResult{Lines: []string{"no stack is installed here"}}
	}
	byName := map[string]stack.Stack{}
	for _, s := range stacks {
		byName[s.Name] = s
	}
	var res CheckResult
	for _, r := range recs {
		s, ok := byName[r.Name]
		if !ok {
			res.Lines = append(res.Lines, r.Name+": orphaned")
			continue
		}
		line, notOK := stackLine(cfg, s, r)
		res.Lines = append(res.Lines, line)
		res.NotOK = res.NotOK || notOK
	}
	if only != "" {
		return res
	}
	extra, err := unexpected(cfg.SvrDir, recs)
	if err != nil {
		res.Lines = append(res.Lines, fmt.Sprintf("error: cannot read %s: %v", cfg.SvrDir, err))
	}
	res.Lines = append(res.Lines, extra...)
	return res
}

// stackLine returns the one line for an installed stack, and whether it is not ok.
// A missing check step gives a not yet line, which is not a failure.
func stackLine(cfg CheckConfig, s stack.Stack, r record.Record) (string, bool) {
	if what, fix, bad := problem(cfg, s, r); bad {
		return fmt.Sprintf("%s: not ok: %s; fix: %s", s.Name, what, fix), true
	}
	path := filepath.Join(s.Dir, "check")
	if !runnable(path) {
		return s.Name + ": not yet: check step", false
	}
	return runCheck(s, path)
}

// problem returns the first thing wrong with an installed stack, in the order
// the spec lists it, with the one command that fixes it.
func problem(cfg CheckConfig, s stack.Stack, r record.Record) (what, fix string, bad bool) {
	apply := "setup-stacks.sh --stack " + s.Name + " --apply"
	if r.Version != s.Version {
		return fmt.Sprintf("recorded v%s, catalog v%s", r.Version, s.Version), apply, true
	}
	for _, u := range s.Units {
		enabled, active := cfg.UnitState(u)
		if !active {
			return fmt.Sprintf("unit %s is not active", u), "sudo systemctl enable --now " + u, true
		}
		if !enabled {
			return fmt.Sprintf("unit %s is not enabled", u), "sudo systemctl enable --now " + u, true
		}
	}
	for _, d := range folders {
		p := filepath.Join(cfg.SvrDir, s.Name, d)
		if fi, err := os.Stat(p); err != nil || !fi.IsDir() {
			return fmt.Sprintf("folder %s is missing", p), apply, true
		}
	}
	return "", "", false
}

// runCheck runs the stack's check step. Its first line decides: "ok..." with
// exit 0 is ok; "not ok: ..." is used as the stack's own text; anything else
// is a failure that names the exit status.
func runCheck(s stack.Stack, path string) (string, bool) {
	cmd := exec.Command(path)
	cmd.Dir = s.Dir
	out, err := cmd.Output()
	first, _, _ := strings.Cut(string(out), "\n")
	first = strings.TrimSpace(first)
	switch {
	case err == nil && strings.HasPrefix(first, "ok"):
		return s.Name + ": ok", false
	case strings.HasPrefix(first, "not ok:"):
		return s.Name + ": " + first, true
	}
	what := "check step did not print ok"
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		what = fmt.Sprintf("check step exited %d", exit.ExitCode())
	} else if err != nil {
		what = "check step could not run: " + err.Error()
	}
	return fmt.Sprintf("%s: not ok: %s; fix: setup-stacks.sh --stack %s --apply", s.Name, what, s.Name), true
}

// runnable reports whether path is a regular file with an execute bit set.
func runnable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}

// unexpected names each entry under svrDir that is not a folder named like an
// installed stack, except lost+found. A missing svrDir has none.
func unexpected(svrDir string, recs []record.Record) ([]string, error) {
	entries, err := os.ReadDir(svrDir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	installed := map[string]bool{}
	for _, r := range recs {
		installed[r.Name] = true
	}
	var out []string
	for _, e := range entries {
		if e.Name() == "lost+found" || (e.IsDir() && installed[e.Name()]) {
			continue
		}
		out = append(out, "not a stack folder: "+filepath.Join(svrDir, e.Name()))
	}
	return out, nil
}

// keepNamed returns the records called name.
func keepNamed(recs []record.Record, name string) []record.Record {
	var out []record.Record
	for _, r := range recs {
		if r.Name == name {
			out = append(out, r)
		}
	}
	return out
}
