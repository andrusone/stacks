package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"stacks/internal/record"
	"stacks/internal/stack"
)

// Exec runs a command and returns its combined output. dir is the working folder ("" is the current one).
type Exec func(dir, name string, args ...string) (string, error)

// Apply installs or updates one stack (SI-FR-07). It runs Plan first and stops, running nothing, when the
// plan is blocked. Otherwise, in order: the run-as user, the stack folders the plan lists, the stack's
// install apply step when its plan has work, its check step when it is executable, and last the record
// when the plan has one. A step whose plan line is missing is not run again, so a rerun changes nothing.
// It returns the lines to print; on an error no record is written.
func Apply(cfg Config, ex Exec, s stack.Stack, installed []record.Record, commit string) ([]string, error) {
	plan := Plan(cfg, s, installed)
	if plan.Blocked {
		return plan.Lines, fmt.Errorf("error: %s is blocked: fix the blocked: lines, then run --apply again", s.Name)
	}
	var out []string
	changes := 0
	done := func(what string) {
		out = append(out, "done: "+what)
		changes++
	}

	if hasLinePrefix(plan.Lines, "would: create system user "+s.User+" ") {
		if _, err := runStep(ex, "", "create system user "+s.User,
			"sudo", "useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", s.User); err != nil {
			return out, err
		}
		done("created system user " + s.User)
	}
	for _, d := range stackFolders {
		path := filepath.Join(cfg.SvrDir, s.Name, d)
		if !hasLinePrefix(plan.Lines, "would: create "+path+" ") && !hasLinePrefix(plan.Lines, "would: correct "+path+" ") {
			continue
		}
		if _, err := runStep(ex, "", "folder "+path,
			"sudo", "install", "-d", "-o", s.User, "-g", s.User, "-m", "750", path); err != nil {
			return out, err
		}
		done("folder " + path)
	}

	stepLines, stepChanges := planStep(s)
	if stepChanges > 0 || countWould(stepLines) > 0 {
		text, err := runStep(ex, s.Dir, "install apply of "+s.Name, filepath.Join(s.Dir, "install"), "apply")
		lines, n := stepOutput(text)
		out = append(out, lines...)
		if err != nil {
			return out, err
		}
		changes += n
	}
	if check := filepath.Join(s.Dir, "check"); runnable(check) {
		if _, err := runStep(ex, s.Dir, "check step of "+s.Name, check); err != nil {
			return out, err
		}
		out = append(out, "done: check step passed")
	}
	if len(recordLines(cfg, s, installed)) > 0 {
		if err := writeRecord(ex, cfg, s, commit); err != nil {
			return out, err
		}
		done("record " + filepath.Join(cfg.RecordsDir, s.Name))
	}
	out = append(out, fmt.Sprintf("changes: %d", changes))
	return out, nil
}

// writeRecord writes the record into a temporary folder, then installs it into RecordsDir with sudo, so
// the records folder is written by the same steps as the rest (SI-FR-07).
func writeRecord(ex Exec, cfg Config, s stack.Stack, commit string) error {
	tmp, err := os.MkdirTemp("", "setup-stacks-record-")
	if err != nil {
		return fmt.Errorf("error: cannot make a temporary folder: %v", err)
	}
	defer os.RemoveAll(tmp)
	r := record.Record{Name: s.Name, Version: s.Version, Commit: commit, Ports: s.Ports, NasPaths: s.NasPaths, Units: s.Units}
	if err := record.Write(tmp, r); err != nil {
		return fmt.Errorf("error: cannot write the record for %s: %v", s.Name, err)
	}
	if _, err := runStep(ex, "", "records folder "+cfg.RecordsDir,
		"sudo", "install", "-d", "-m", "755", cfg.RecordsDir); err != nil {
		return err
	}
	_, err = runStep(ex, "", "record "+s.Name,
		"sudo", "install", "-m", "644", filepath.Join(tmp, s.Name), filepath.Join(cfg.RecordsDir, s.Name))
	return err
}

// runStep runs one command through ex. A failure is an error that names what failed and the command's
// last line of output; the output is returned either way.
func runStep(ex Exec, dir, what, name string, args ...string) (string, error) {
	text, err := ex(dir, name, args...)
	if err != nil {
		return text, fmt.Errorf("error: %s failed: %s", what, lastLine(text, err))
	}
	return text, nil
}

// stepOutput splits a step's output into the lines to copy through and the changes: n it reports (0 when
// it reports none). The changes: line itself is not copied, because Apply prints its own last.
func stepOutput(text string) ([]string, int) {
	var lines []string
	n := 0
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "changes:") {
			if v, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "changes:"))); err == nil {
				n += v
			}
			continue
		}
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	return lines, n
}

// lastLine returns the last non-empty line of text, or the error's text when there is none.
func lastLine(text string, fallback error) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
		return last
	}
	return fallback.Error()
}

// hasLinePrefix reports whether any line starts with prefix.
func hasLinePrefix(lines []string, prefix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}
