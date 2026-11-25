package main

import (
	"fmt"
	"io"
	"os/exec"
	"strings"

	"stacks/internal/installer"
	"stacks/internal/record"
	"stacks/internal/stack"
)

// applyRun is --stack <name> --apply (SI-FR-07): the preflight, the installed records, the commit of the
// clone, then installer.Apply with the env's commands. It prints every line and exits 1 on any error.
func applyRun(stdout, stderr io.Writer, e env, s stack.Stack) int {
	if err := installer.Preflight(e.Pre); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer installer.Release(e.Pre.LockPath)
	installed, err := record.List(e.Cfg.RecordsDir)
	if err != nil {
		fmt.Fprintf(stderr, "error: cannot read the installed records in %s: %v\n", e.Cfg.RecordsDir, err)
		return 1
	}
	head, err := e.Exec("", "git", "-C", e.Cfg.CloneDir, "rev-parse", "HEAD")
	if err != nil {
		fmt.Fprintf(stderr, "error: cannot read the commit of %s: %s\n", e.Cfg.CloneDir, strings.TrimSpace(head))
		return 1
	}
	lines, err := installer.Apply(e.Cfg, e.Exec, s, installed, strings.TrimSpace(head))
	for _, line := range lines {
		fmt.Fprintln(stdout, line)
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

// realExec runs a command on this machine and returns its combined output. dir "" is the current folder.
func realExec(dir, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}
