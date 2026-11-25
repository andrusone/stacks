package installer

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"stacks/internal/record"
)

// fakeRun records every command as one line and runs none of them. Except that sudo install copies a
// file into place, so the record can be read back. out maps a text to the output of a command whose
// line contains it; fail does the same and makes that command exit 1.
type fakeRun struct {
	calls []string
	out   map[string]string
	fail  map[string]string
}

func (r *fakeRun) exec(dir, name string, args ...string) (string, error) {
	call := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.calls = append(r.calls, call)
	for text, out := range r.fail {
		if strings.Contains(call, text) {
			return out, errors.New("exit status 1")
		}
	}
	text := ""
	for key, out := range r.out {
		if strings.Contains(call, key) {
			text = out
		}
	}
	if name == "sudo" && len(args) > 0 && args[0] == "install" {
		dst := args[len(args)-1]
		if args[1] == "-d" {
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return "", err
			}
		} else {
			data, err := os.ReadFile(args[len(args)-2])
			if err != nil {
				return "", err
			}
			if err := os.WriteFile(dst, data, 0o644); err != nil {
				return "", err
			}
		}
	}
	return text, nil
}

// planScript is an install step whose plan prints the given lines. Apply's own runs are faked by fakeRun,
// so the step's apply body is never executed here.
func planScript(plan string) string {
	return "#!/bin/sh\ncase \"$1\" in plan) " + plan + " ;; esac\n"
}

// firstInstallPlan has one change until the marker file "installed" exists, which the test makes once
// the first apply has run.
const firstInstallPlan = `if [ ! -e installed ]; then echo 'would: install demo'; echo 'changes: 1'; fi`

func TestApplyFirstInstallRunsStepsInOrderAndWritesRecordLast(t *testing.T) {
	f := newPlanFixture(t, planScript(firstInstallPlan))
	writeCheck(t, f.stack.Dir, "exit 0")
	r := &fakeRun{out: map[string]string{"install apply": "installed demo\nchanges: 1\n"}}
	lines, err := Apply(f.cfg, r.exec, f.stack, nil, "abc1234")
	if err != nil {
		t.Fatalf("Apply: %v\n%s", err, strings.Join(lines, "\n"))
	}
	dir := f.stack.Dir
	want := []string{
		"sudo useradd --system --no-create-home --shell /usr/sbin/nologin stk-demo",
		"sudo install -d -o stk-demo -g stk-demo -m 750 " + f.folder("data"),
		"sudo install -d -o stk-demo -g stk-demo -m 750 " + f.folder("logs"),
		"sudo install -d -o stk-demo -g stk-demo -m 750 " + f.folder("config"),
		"sudo install -d -o stk-demo -g stk-demo -m 750 " + f.folder("backup"),
		filepath.Join(dir, "install") + " apply",
		filepath.Join(dir, "check"),
		"sudo install -d -m 755 " + f.records,
	}
	if len(r.calls) != len(want)+1 {
		t.Fatalf("calls:\n%s\nwant %d calls, the last being the record", strings.Join(r.calls, "\n"), len(want)+1)
	}
	for i := range want {
		if r.calls[i] != want[i] {
			t.Errorf("call %d = %q, want %q", i, r.calls[i], want[i])
		}
	}
	last := r.calls[len(want)]
	if !strings.HasPrefix(last, "sudo install -m 644 ") || !strings.HasSuffix(last, filepath.Join(f.records, "demo")) {
		t.Errorf("last call %q, want the record installed last", last)
	}
	if got := lines[len(lines)-1]; got != "changes: 7" {
		t.Errorf("last line %q, want changes: 7 (user, four folders, the step's 1, the record)", got)
	}
	if !hasLinePrefix(lines, "installed demo") {
		t.Errorf("the step's output was not copied through: %q", lines)
	}
	rec, ok, err := record.Read(f.records, "demo")
	if err != nil || !ok {
		t.Fatalf("record not written: ok %v err %v", ok, err)
	}
	if rec.Version != "1.0.0" || rec.Commit != "abc1234" {
		t.Errorf("record = %+v, want version 1.0.0 commit abc1234", rec)
	}
}

func TestApplyFailingInstallStepWritesNoRecord(t *testing.T) {
	f := newPlanFixture(t, planScript(firstInstallPlan))
	r := &fakeRun{fail: map[string]string{"install apply": "half done\nboom at step two\n"}}
	_, err := Apply(f.cfg, r.exec, f.stack, nil, "abc1234")
	if err == nil || !strings.Contains(err.Error(), "boom at step two") {
		t.Fatalf("err = %v, want the step's last line", err)
	}
	if _, ok, _ := record.Read(f.records, "demo"); ok {
		t.Error("a record was written after a failed install step")
	}
	for _, c := range r.calls {
		if strings.Contains(c, "install -m 644") {
			t.Errorf("record installed after a failure: %q", c)
		}
	}
}

func TestApplyFailingCheckStepWritesNoRecord(t *testing.T) {
	f := newPlanFixture(t, planScript(firstInstallPlan))
	writeCheck(t, f.stack.Dir, "exit 1")
	r := &fakeRun{fail: map[string]string{filepath.Join(f.stack.Dir, "check"): "not ok: units down\n"}}
	_, err := Apply(f.cfg, r.exec, f.stack, nil, "abc1234")
	if err == nil || !strings.Contains(err.Error(), "not ok: units down") {
		t.Fatalf("err = %v, want the check step's last line", err)
	}
	if _, ok, _ := record.Read(f.records, "demo"); ok {
		t.Error("a record was written after a failed check step")
	}
}

func TestApplyBlockedPlanRunsNothing(t *testing.T) {
	f := newPlanFixture(t, planScript(firstInstallPlan))
	// An empty env file leaves A with no value: the plan is blocked.
	if err := os.WriteFile(filepath.Join(f.envDir, "demo.env"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	r := &fakeRun{}
	lines, err := Apply(f.cfg, r.exec, f.stack, nil, "abc1234")
	if err == nil {
		t.Fatal("Apply succeeded with a blocked plan")
	}
	if len(r.calls) != 0 {
		t.Errorf("ran %v, want nothing", r.calls)
	}
	if !hasLinePrefix(lines, "blocked: ") {
		t.Errorf("lines %q, want the blocked: lines", lines)
	}
}

func TestApplySecondRunChangesNothing(t *testing.T) {
	f := newPlanFixture(t, planScript(firstInstallPlan))
	// The user and folders are right already, so the first apply changes only the step and the record.
	f.settle(t)
	f.installed = nil
	writeCheck(t, f.stack.Dir, "exit 0")
	r := &fakeRun{out: map[string]string{"install apply": "changes: 1\n"}}
	if _, err := Apply(f.cfg, r.exec, f.stack, nil, "abc1234"); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	// The step's plan no longer has work once its apply has run.
	if err := os.WriteFile(filepath.Join(f.stack.Dir, "installed"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	installed, err := record.List(f.records)
	if err != nil {
		t.Fatal(err)
	}
	r2 := &fakeRun{}
	lines, err := Apply(f.cfg, r2.exec, f.stack, installed, "abc1234")
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	// Only the check step runs (it has no plan line and always runs when executable).
	if len(r2.calls) != 1 || r2.calls[0] != filepath.Join(f.stack.Dir, "check") {
		t.Errorf("second apply ran %v, want only the check step", r2.calls)
	}
	if len(lines) != 2 || lines[0] != "done: check step passed" || lines[1] != "changes: 0" {
		t.Errorf("lines %q, want the check line and changes: 0", lines)
	}
}

func TestApplyUpdateRunsStepAndRewritesRecord(t *testing.T) {
	f := newPlanFixture(t, planScript("echo 'would: update demo'; echo 'changes: 1'"))
	f.settle(t)
	f.installed = []record.Record{{Name: "demo", Version: "0.9.0"}}
	r := &fakeRun{out: map[string]string{"install apply": "updated demo\nchanges: 1\n"}}
	lines, err := Apply(f.cfg, r.exec, f.stack, f.installed, "abc1234")
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if len(r.calls) != 3 || !strings.HasSuffix(r.calls[0], " apply") {
		t.Errorf("calls %v, want the step, then the record's two commands", r.calls)
	}
	if got := lines[len(lines)-1]; got != "changes: 2" {
		t.Errorf("last line %q, want changes: 2 (the step's 1 and the record's 1)", got)
	}
	rec, ok, _ := record.Read(f.records, "demo")
	if !ok || rec.Version != "1.0.0" {
		t.Errorf("record = %+v ok %v, want version 1.0.0", rec, ok)
	}
}

// writeCheck gives the stack an executable check step with the given shell body.
func writeCheck(t *testing.T, dir, body string) {
	t.Helper()
	planWrite(t, filepath.Join(dir, "check"), "#!/bin/sh\n"+body+"\n", 0o755)
}
