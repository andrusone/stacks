package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// fakeCommands records every command through env.Exec and runs none. git rev-parse answers with a commit;
// "install apply" answers with the given output and error; everything else is quiet and succeeds.
type fakeCommands struct {
	calls   []string
	applyOK bool
	applyTx string
}

func (f *fakeCommands) exec(dir, name string, args ...string) (string, error) {
	call := strings.TrimSpace(name + " " + strings.Join(args, " "))
	f.calls = append(f.calls, call)
	switch {
	case name == "git":
		return "abc1234\n", nil
	case strings.HasSuffix(call, "install apply"):
		if !f.applyOK {
			return f.applyTx, fmt.Errorf("exit status 1")
		}
		return f.applyTx, nil
	}
	return "", nil
}

// applyEnv is a test env for --apply: a stack alpha with a plan that has one step change, and the fake
// commands. The records and folders do not exist yet, so the first apply makes them all.
func applyEnv(t *testing.T) (env, *fakeCommands, string) {
	t.Helper()
	stacks := t.TempDir()
	writeStack(t, stacks, "alpha", "first one")
	writeInstall(t, stacks, "alpha", "would: install alpha step", "changes: 1")
	e, _ := testEnv(t, stacks)
	// Every stack needs its env file, even an empty one when it has no values (as the dry run tests do).
	writeFile(t, filepath.Join(e.Cfg.EnvDir, "alpha.env"), "")
	fc := &fakeCommands{applyOK: true, applyTx: "alpha step ran\nchanges: 1\n"}
	e.Exec = fc.exec
	return e, fc, stacks
}

// --apply through runWith prints each line, the step's output included, ends with changes: n and exits 0.
func TestApplyThroughRunWithPrintsLinesAndExitsZero(t *testing.T) {
	e, fc, _ := applyEnv(t)
	code, out, errs := runEnv(e, "--stack", "alpha", "--apply")
	if code != 0 || errs != "" {
		t.Fatalf("exit %d, stderr %q; want 0 and nothing on stderr\n%s", code, errs, out)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if last := lines[len(lines)-1]; last != "changes: 6" {
		t.Errorf("last line %q, want changes: 6 (four folders, the step's 1, the record)\n%s", last, out)
	}
	for _, want := range []string{"alpha step ran", "done: record " + filepath.Join(e.Cfg.RecordsDir, "alpha")} {
		if !strings.Contains(out, want) {
			t.Errorf("stdout has no %q:\n%s", want, out)
		}
	}
	if !strings.Contains(strings.Join(fc.calls, "\n"), "git -C "+e.Cfg.CloneDir+" rev-parse HEAD") {
		t.Errorf("the commit was not read from the clone: %v", fc.calls)
	}
}

// A failing install step exits 1, prints its last line on stderr, and never installs the record.
func TestApplyFailingStepExitsOneWithItsLastLine(t *testing.T) {
	e, fc, _ := applyEnv(t)
	fc.applyOK = false
	fc.applyTx = "half\nboom at the step\n"
	code, _, errs := runEnv(e, "--stack", "alpha", "--apply")
	if code != 1 || !strings.Contains(errs, "boom at the step") {
		t.Errorf("exit %d, stderr %q; want 1 and the step's last line", code, errs)
	}
	for _, c := range fc.calls {
		if strings.Contains(c, "install -m 644") {
			t.Errorf("the record was installed after a failure: %q", c)
		}
	}
}

// Root stops at the preflight with the root line and runs no command.
func TestApplyRootStopsWithOneLine(t *testing.T) {
	e, fc, _ := applyEnv(t)
	e.Pre.UID = 0
	code, out, errs := runEnv(e, "--stack", "alpha", "--apply")
	if code != 1 || out != "" || !strings.Contains(errs, "not root") {
		t.Errorf("exit %d, stdout %q, stderr %q; want 1, empty stdout, the root line", code, out, errs)
	}
	if len(fc.calls) != 0 {
		t.Errorf("ran %v, want nothing", fc.calls)
	}
}
