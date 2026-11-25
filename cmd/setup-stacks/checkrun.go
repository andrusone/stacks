package main

import (
	"fmt"
	"io"
	"os/exec"

	"stacks/internal/installer"
	"stacks/internal/stack"
)

// checkRun is --check and --check --stack <name> (SI-FR-08): it prints what installer.Check finds and
// changes nothing. It exits 1 when a stack is not ok, else 0. Like the dry run it runs the preflight
// (user and OS, and the lock for the run).
func checkRun(stdout, stderr io.Writer, e env, stacks []stack.Stack, only string) int {
	if err := installer.Preflight(e.Pre); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer installer.Release(e.Pre.LockPath)
	res := installer.Check(installer.CheckConfig{SvrDir: e.Cfg.SvrDir, RecordsDir: e.Cfg.RecordsDir, UnitState: e.Unit}, stacks, only)
	for _, line := range res.Lines {
		fmt.Fprintln(stdout, line)
	}
	if res.NotOK {
		return 1
	}
	return 0
}

// unitState asks systemd whether a unit is enabled and whether it is active (SI-FR-08).
func unitState(unit string) (enabled, active bool) {
	enabled = exec.Command("systemctl", "is-enabled", "--quiet", unit).Run() == nil
	active = exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil
	return enabled, active
}
