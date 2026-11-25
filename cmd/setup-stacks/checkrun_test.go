package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"stacks/internal/record"
)

// installedAlpha makes stack alpha installed and ok in e: its record, its four folders, and a check step
// that prints ok. Every unit is fake: enabled and active. It returns e with that fake unit state.
func installedAlpha(t *testing.T, e env, stacks string) env {
	t.Helper()
	writeStack(t, stacks, "alpha", "first one")
	writeFile(t, filepath.Join(stacks, "alpha", "check"), "#!/bin/sh\necho ok\n")
	if err := os.Chmod(filepath.Join(stacks, "alpha", "check"), 0o755); err != nil {
		t.Fatal(err)
	}
	installRecord(t, e, "alpha")
	e.Unit = func(string) (bool, bool) { return true, true }
	return e
}

// installRecord writes the record for name at the stack's version "1" and makes its four folders.
func installRecord(t *testing.T, e env, name string) {
	t.Helper()
	if err := record.Write(e.Cfg.RecordsDir, record.Record{
		Name: name, Version: "1", Commit: "abc1234", Ports: []int{8080}, Units: []string{name + ".service"},
	}); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"data", "logs", "config", "backup"} {
		if err := os.MkdirAll(filepath.Join(e.Cfg.SvrDir, name, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

// An ok stack prints its ok line and exits 0.
func TestCheckOkStackExitsZero(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	code, out, errs := runEnv(e, "--check")
	if code != 0 || out != "alpha: ok\n" || errs != "" {
		t.Errorf("exit %d, stdout %q, stderr %q; want 0, \"alpha: ok\\n\", empty", code, out, errs)
	}
}

// A stack whose unit is not active prints one not ok line with the fix, and exits 1.
func TestCheckNotOkStackExitsOne(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	e.Unit = func(string) (bool, bool) { return true, false }
	code, out, _ := runEnv(e, "--check")
	want := "alpha: not ok: unit alpha.service is not active; fix: sudo systemctl enable --now alpha.service\n"
	if code != 1 || out != want {
		t.Errorf("exit %d, stdout %q; want 1, %q", code, out, want)
	}
}

// Nothing installed says so and exits 0.
func TestCheckNothingInstalled(t *testing.T) {
	stacks := t.TempDir()
	writeStack(t, stacks, "alpha", "first one")
	e, _ := testEnv(t, stacks)
	e.Unit = func(string) (bool, bool) { return true, true }
	code, out, errs := runEnv(e, "--check")
	if code != 0 || out != "no stack is installed here\n" || errs != "" {
		t.Errorf("exit %d, stdout %q, stderr %q; want 0 and the nothing-installed line", code, out, errs)
	}
}

// --check --stack <name> prints only that stack, even when another is installed and not ok.
func TestCheckStackPrintsOnlyThatStack(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	writeStack(t, stacks, "beta", "second one")
	installRecord(t, e, "beta")
	e.Unit = func(unit string) (bool, bool) { return true, unit != "beta.service" }
	code, out, _ := runEnv(e, "--check", "--stack", "alpha")
	if code != 0 || out != "alpha: ok\n" {
		t.Errorf("exit %d, stdout %q; want 0 and only alpha", code, out)
	}
}

// --check --stack for a name that is not installed, and not in the folder, says so and exits 0: the
// unknown-stack error does not apply to --check.
func TestCheckStackNotInstalledExitsZero(t *testing.T) {
	stacks := t.TempDir()
	writeStack(t, stacks, "alpha", "first one")
	e, _ := testEnv(t, stacks)
	e.Unit = func(string) (bool, bool) { return true, true }
	code, out, errs := runEnv(e, "--check", "--stack", "nosuch")
	if code != 0 || out != "nosuch is not installed here\n" || errs != "" {
		t.Errorf("exit %d, stdout %q, stderr %q; want 0 and the not-installed line", code, out, errs)
	}
}

// An installed name with no folder in the stacks folder is orphaned, not an error.
func TestCheckOrphanedExitsZero(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	installRecord(t, e, "gone")
	e.Unit = func(string) (bool, bool) { return true, true }
	code, out, _ := runEnv(e, "--check", "--stack", "gone")
	if code != 0 || out != "gone: orphaned\n" {
		t.Errorf("exit %d, stdout %q; want 0 and orphaned", code, out)
	}
}

// Root stops at the preflight with the root line and exit 1, before anything is read.
func TestCheckRootStopsWithOneLine(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	e.Pre.UID = 0
	code, out, errs := runEnv(e, "--check")
	if code != 1 || out != "" || !strings.Contains(errs, "not root") {
		t.Errorf("exit %d, stdout %q, stderr %q; want 1, empty stdout, the root line", code, out, errs)
	}
}

// A held lock stops the check with exit 1 and leaves the other run's lock alone.
func TestCheckHeldLockStops(t *testing.T) {
	stacks := t.TempDir()
	e, _ := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	// This test process is alive, so the lock is held, not stale.
	writeFile(t, e.Pre.LockPath, fmt.Sprintf("%d\n", os.Getpid()))
	code, out, errs := runEnv(e, "--check")
	if code != 1 || out != "" || !strings.Contains(errs, "another setup-stacks run is in progress") {
		t.Errorf("exit %d, stdout %q, stderr %q; want 1 and the in-progress line", code, out, errs)
	}
	if _, err := os.Stat(e.Pre.LockPath); err != nil {
		t.Errorf("the other run's lock was removed: %v", err)
	}
}

// Check changes nothing: the tree is the same before and after.
func TestCheckChangesNothing(t *testing.T) {
	stacks := t.TempDir()
	e, root := testEnv(t, stacks)
	e = installedAlpha(t, e, stacks)
	before := snapshot(t, root, stacks)
	runEnv(e, "--check")
	if after := snapshot(t, root, stacks); after != before {
		t.Errorf("the tree changed:\nbefore:\n%s\nafter:\n%s", before, after)
	}
}
