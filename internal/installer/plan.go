package installer

import (
	"bytes"
	"fmt"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"stacks/internal/record"
	"stacks/internal/stack"
)

// Config is where Plan looks. Every path is passed in so tests use temp folders.
type Config struct {
	SvrDir, RecordsDir, EnvDir, CloneDir, MountsPath string
	UserExists                                       func(string) bool // nil means os/user.Lookup
}

// PlanResult is the dry run for one stack (SI-FR-05). Lines are in order and the last is "changes: n".
type PlanResult struct {
	Lines   []string
	Changes int
	Blocked bool
}

// Plan lists every change a stack install would make and every blocker (SI-FR-05).
// It changes nothing on disk; the only thing it runs is the stack's install plan step.
func Plan(cfg Config, s stack.Stack, installed []record.Record) PlanResult {
	var lines []string
	lines = append(lines, Blockers(BlockerInput{
		Stack:      s,
		EnvFile:    filepath.Join(cfg.EnvDir, s.Name+".env"),
		ExampleEnv: filepath.Join(s.Dir, "example.env"),
		CloneDir:   cfg.CloneDir,
		SvrDir:     cfg.SvrDir,
		MountsPath: cfg.MountsPath,
	})...)
	candidate := record.Record{Name: s.Name, Version: s.Version, Ports: s.Ports, NasPaths: s.NasPaths, Units: s.Units}
	for _, c := range record.Clash(candidate, installed) {
		lines = append(lines, "blocked: "+c)
	}

	changes := 0
	own := func(group []string) {
		lines = append(lines, group...)
		changes += countWould(group)
	}
	exists := userExists(cfg, s.User)
	if !exists {
		own([]string{"would: create system user " + s.User + " (no login)"})
	}
	own(folderLines(cfg, s, exists))

	stepLines, stepChanges := planStep(s)
	lines = append(lines, stepLines...)
	changes += stepChanges

	own(recordLines(cfg, s, installed))

	lines = append(lines, fmt.Sprintf("changes: %d", changes))
	return PlanResult{Lines: lines, Changes: changes, Blocked: anyBlocked(lines)}
}

// userExists uses cfg.UserExists when it is set, and os/user otherwise.
func userExists(cfg Config, name string) bool {
	if cfg.UserExists != nil {
		return cfg.UserExists(name)
	}
	_, err := user.Lookup(name)
	return err == nil
}

// planStep runs the stack's install plan step in its folder. Its would: and blocked: lines are copied
// through unchanged and its changes: n is added to the count. Its would: lines are not counted again.
// A failed step with no blocked: line of its own is reported with the first line of its stderr.
func planStep(s stack.Stack) ([]string, int) {
	cmd := exec.Command(filepath.Join(s.Dir, "install"), "plan")
	cmd.Dir = s.Dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	var lines []string
	changes := 0
	blocked := false
	for _, line := range strings.Split(stdout.String(), "\n") {
		switch {
		case strings.HasPrefix(line, "would:"):
			lines = append(lines, line)
		case strings.HasPrefix(line, "blocked:"):
			lines = append(lines, line)
			blocked = true
		case strings.HasPrefix(line, "changes:"):
			if n, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "changes:"))); err == nil {
				changes += n
			}
		}
	}
	if runErr != nil && !blocked {
		lines = append(lines, "blocked: install plan failed: "+firstLine(stderr.String(), runErr))
	}
	return lines, changes
}

// firstLine returns the first non-empty line of text, or the error's text when there is none.
func firstLine(text string, fallback error) string {
	line, _, _ := strings.Cut(strings.TrimSpace(text), "\n")
	if line == "" {
		return fallback.Error()
	}
	return line
}

// recordLines says what the installed record needs: a write when there is none, an update when its
// version differs from the stack's, and nothing when it matches.
func recordLines(cfg Config, s stack.Stack, installed []record.Record) []string {
	for _, r := range installed {
		if r.Name != s.Name {
			continue
		}
		if r.Version != s.Version {
			return []string{fmt.Sprintf("would: update %s from %s to %s", s.Name, r.Version, s.Version)}
		}
		return nil
	}
	return []string{"would: write record " + filepath.Join(cfg.RecordsDir, s.Name)}
}

// countWould counts the lines that start with would:.
func countWould(lines []string) int {
	n := 0
	for _, l := range lines {
		if strings.HasPrefix(l, "would:") {
			n++
		}
	}
	return n
}

// anyBlocked reports whether any line starts with blocked:.
func anyBlocked(lines []string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, "blocked:") {
			return true
		}
	}
	return false
}
