package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"stacks/internal/installer"
)

// testEnv is an env whose every path is in one temp root (returned): a clean git clone, /svr mounted,
// an env folder, a records folder that does not exist yet, an Ubuntu 26.04 os-release, UID 1000, a lock
// in the root and a user that already exists. stacks is the stacks folder the caller made.
func testEnv(t *testing.T, stacks string) (env, string) {
	t.Helper()
	root := t.TempDir()
	e := env{
		Stacks: stacks,
		Cfg: installer.Config{
			SvrDir:     filepath.Join(root, "svr"),
			RecordsDir: filepath.Join(root, "records"),
			EnvDir:     filepath.Join(root, "etc"),
			CloneDir:   filepath.Join(root, "clone"),
			MountsPath: filepath.Join(root, "mounts"),
			UserExists: func(string) bool { return true },
		},
		Pre: installer.PreflightEnv{
			UID:           1000,
			OSReleasePath: filepath.Join(root, "os-release"),
			LockPath:      filepath.Join(root, "lock"),
		},
	}
	for _, d := range []string{e.Cfg.SvrDir, e.Cfg.EnvDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if out, err := exec.Command("git", "init", "-q", e.Cfg.CloneDir).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	writeFile(t, e.Pre.OSReleasePath, "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"26.04\"\n")
	writeMounts(t, e, e.Cfg.SvrDir)
	return e, root
}

// writeFile writes text to path.
func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeMounts writes a mounts file that mounts exactly the given folder ("" mounts nothing).
func writeMounts(t *testing.T, e env, mounted string) {
	t.Helper()
	text := ""
	if mounted != "" {
		text = "tmpfs " + mounted + " tmpfs rw 0 0\n"
	}
	writeFile(t, e.Cfg.MountsPath, text)
}

// writeInstall gives a stack an install script whose plan step prints the given lines.
func writeInstall(t *testing.T, stacks, name string, lines ...string) {
	t.Helper()
	var b strings.Builder
	b.WriteString("#!/bin/sh\n")
	for _, l := range lines {
		fmt.Fprintf(&b, "printf '%%s\\n' '%s'\n", l)
	}
	path := filepath.Join(stacks, name, "install")
	if err := os.WriteFile(path, []byte(b.String()), 0o755); err != nil {
		t.Fatal(err)
	}
}

// snapshot is every path and size under the root and the stacks folder, so a test can see nothing changed.
func snapshot(t *testing.T, root, stacks string) string {
	return listTree(t, root) + "--stacks--\n" + listTree(t, stacks)
}

// runEnv runs the command with an env and returns the exit code and both outputs.
func runEnv(e env, argv ...string) (int, string, string) {
	var out, errb bytes.Buffer
	code := runWith(argv, &out, &errb, e)
	return code, out.String(), errb.String()
}

// stackWithPlan makes a stack alpha with an install step that adds one change, and an env file for it
// (the stack needs no values, so an empty file is enough). It returns the test env, its root and the stacks folder.
func stackWithPlan(t *testing.T) (env, string, string) {
	t.Helper()
	stacks := t.TempDir()
	writeStack(t, stacks, "alpha", "first one")
	writeInstall(t, stacks, "alpha", "would: install alpha step", "changes: 1")
	e, root := testEnv(t, stacks)
	writeFile(t, filepath.Join(e.Cfg.EnvDir, "alpha.env"), "")
	return e, root, stacks
}

// A clean dry run prints the plan, ends with changes: n, exits 0 and changes nothing.
func TestDryRunCleanPrintsPlanAndChangesNothing(t *testing.T) {
	e, root, stacks := stackWithPlan(t)
	before := snapshot(t, root, stacks)
	code, out, errs := runEnv(e, "--stack", "alpha")
	if code != 0 {
		t.Fatalf("exit %d, want 0; stderr %q", code, errs)
	}
	if errs != "" {
		t.Errorf("stderr %q, want empty", errs)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	// four folders to create, the step's one change, the record: six changes.
	if len(lines) != 7 {
		t.Fatalf("got %d lines, want 7:\n%s", len(lines), out)
	}
	if lines[4] != "would: install alpha step" {
		t.Errorf("step line = %q", lines[4])
	}
	if want := "would: write record " + filepath.Join(e.Cfg.RecordsDir, "alpha"); lines[5] != want {
		t.Errorf("record line = %q, want %q", lines[5], want)
	}
	if lines[6] != "changes: 6" {
		t.Errorf("last line = %q, want changes: 6", lines[6])
	}
	if after := snapshot(t, root, stacks); after != before {
		t.Errorf("a dry run changed the disk:\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

// A blocked stack exits 1 and still lists its would: lines.
func TestDryRunBlockedStillListsWouldLines(t *testing.T) {
	e, root, stacks := stackWithPlan(t)
	if err := os.Remove(filepath.Join(e.Cfg.EnvDir, "alpha.env")); err != nil {
		t.Fatal(err)
	}
	before := snapshot(t, root, stacks)
	code, out, errs := runEnv(e, "--stack", "alpha")
	if code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if errs != "" {
		t.Errorf("stderr %q, want empty", errs)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if want := "blocked: " + filepath.Join(e.Cfg.EnvDir, "alpha.env") + " is missing"; lines[0] != want {
		t.Errorf("first line %q, want %q", lines[0], want)
	}
	if !strings.Contains(out, "would: install alpha step") {
		t.Errorf("would: lines missing:\n%s", out)
	}
	if last := lines[len(lines)-1]; !strings.HasPrefix(last, "changes: ") {
		t.Errorf("last line %q, want changes: n", last)
	}
	if after := snapshot(t, root, stacks); after != before {
		t.Errorf("a blocked dry run changed the disk")
	}
}

// Each preflight failure stops before any plan: one line on stderr, exit 1, nothing on stdout.
func TestDryRunPreflightStopsWithOneLine(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, e *env)
		want  string
	}{
		{"root", func(t *testing.T, e *env) {
			e.Pre.UID = 0
		}, "error: run this as your normal user, not root; it calls sudo itself"},
		{"other OS", func(t *testing.T, e *env) {
			writeFile(t, e.Pre.OSReleasePath, "ID=fedora\nVERSION_ID=\"40\"\n")
		}, "error: this runs only on Ubuntu 26.04 (found fedora 40)"},
		{"held lock", func(t *testing.T, e *env) {
			writeFile(t, e.Pre.LockPath, fmt.Sprintf("%d\n", os.Getpid()))
		}, fmt.Sprintf("error: another setup-stacks run is in progress (pid %d)", os.Getpid())},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, root, stacks := stackWithPlan(t)
			c.setup(t, &e)
			before := snapshot(t, root, stacks)
			code, out, errs := runEnv(e, "--stack", "alpha")
			if code != 1 {
				t.Errorf("exit %d, want 1", code)
			}
			if out != "" {
				t.Errorf("stdout %q, want empty", out)
			}
			if errs != c.want+"\n" {
				t.Errorf("stderr %q, want %q", errs, c.want+"\n")
			}
			if after := snapshot(t, root, stacks); after != before {
				t.Errorf("a stopped run changed the disk:\nbefore:\n%s\nafter:\n%s", before, after)
			}
		})
	}
}

// Problems in the clone or /svr block the plan too: the blocked line names them and exit is 1.
func TestDryRunCloneAndMountBlock(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, e *env)
		want  string
	}{
		{"dirty clone", func(t *testing.T, e *env) {
			writeFile(t, filepath.Join(e.Cfg.CloneDir, "scratch.txt"), "x")
		}, "has uncommitted changes"},
		{"svr not mounted", func(t *testing.T, e *env) {
			writeMounts(t, *e, "")
		}, "is not a mounted filesystem"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, _, _ := stackWithPlan(t)
			c.setup(t, &e)
			code, out, errs := runEnv(e, "--stack", "alpha")
			if code != 1 {
				t.Errorf("exit %d, want 1; stderr %q", code, errs)
			}
			if !strings.Contains(out, "blocked: ") || !strings.Contains(out, c.want) {
				t.Errorf("stdout does not name the problem (%q):\n%s", c.want, out)
			}
		})
	}
}

// Flag errors, no flags, an unknown stack and --help never reach the preflight: they behave as before even
// as root, which the preflight would refuse. (--apply runs it: applyrun_test.go covers root.)
func TestPreflightNotCalledByOtherPaths(t *testing.T) {
	stacks := t.TempDir()
	writeStack(t, stacks, "alpha", "first one")
	e, _ := testEnv(t, stacks)
	e.Pre.UID = 0
	cases := []struct {
		argv []string
		code int
	}{
		{[]string{"--help"}, 0},
		{nil, 1},
		{[]string{"--stack", "nosuch"}, 1},
		{[]string{"--bogus"}, 2},
	}
	for _, c := range cases {
		code, _, errs := runEnv(e, c.argv...)
		if code != c.code {
			t.Errorf("%q: exit %d, want %d", c.argv, code, c.code)
		}
		if strings.Contains(errs, "not root") {
			t.Errorf("%q: the preflight ran: %q", c.argv, errs)
		}
	}
}

// realEnv names this machine's paths from the home folder.
func TestRealEnvPaths(t *testing.T) {
	t.Setenv("STACKS_DIR", "")
	e := realEnv("/home/tester")
	if e.Stacks != "/home/tester/src/stacks/stacks" {
		t.Errorf("Stacks = %q", e.Stacks)
	}
	if e.Cfg.SvrDir != "/svr" || e.Cfg.RecordsDir != "/var/lib/stacks" || e.Cfg.EnvDir != "/etc/stacks" {
		t.Errorf("Cfg = %+v", e.Cfg)
	}
	if e.Cfg.CloneDir != "/home/tester/src/stacks" || e.Cfg.MountsPath != "/proc/self/mounts" {
		t.Errorf("Cfg = %+v", e.Cfg)
	}
	if e.Pre.OSReleasePath != "/etc/os-release" || e.Pre.LockPath != "/tmp/setup-stacks.lock" {
		t.Errorf("Pre = %+v", e.Pre)
	}
}
