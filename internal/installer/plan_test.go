package installer

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"testing"

	"stacks/internal/record"
	"stacks/internal/stack"
)

// planFixture is a stack folder with an install step, and a temp /svr, records, env folder, clone and
// mounts file. Nothing real is read or written.
type planFixture struct {
	cfg       Config
	stack     stack.Stack
	installed []record.Record
	svr       string
	records   string
	envDir    string
}

func planWrite(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

func newPlanFixture(t *testing.T, step string) *planFixture {
	t.Helper()
	root := t.TempDir()
	f := &planFixture{
		svr:     filepath.Join(root, "svr"),
		records: filepath.Join(root, "records"),
		envDir:  filepath.Join(root, "env"),
	}
	stackDir := filepath.Join(root, "stacks", "demo")
	for _, d := range []string{f.svr, f.envDir, stackDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	planWrite(t, filepath.Join(f.envDir, "demo.env"), "A=1\n", 0o600)
	planWrite(t, filepath.Join(stackDir, "example.env"), "A=changeme\n", 0o644)
	planWrite(t, filepath.Join(stackDir, "install"), step, 0o755)
	clone := filepath.Join(root, "clone")
	if err := exec.Command("git", "init", "-q", clone).Run(); err != nil {
		t.Fatal(err)
	}
	mounts := filepath.Join(root, "mounts")
	planWrite(t, mounts, "/dev/sdb1 "+f.svr+" ext4 rw 0 0\n", 0o644)
	f.cfg = Config{
		SvrDir: f.svr, RecordsDir: f.records, EnvDir: f.envDir, CloneDir: clone, MountsPath: mounts,
		UserExists: func(string) bool { return false },
	}
	f.stack = stack.Stack{
		Name: "demo", Version: "1.0.0", User: "stk-demo", Units: []string{"stk-demo.service"},
		Ports: []int{18000}, NasPaths: []string{"/nas/demo"}, Env: []string{"A"}, Dir: stackDir,
	}
	return f
}

// settle makes the run-as user, the four folders and the record right, so a test changes only one thing.
func (f *planFixture) settle(t *testing.T) {
	t.Helper()
	cur, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	f.stack.User = cur.Username
	f.cfg.UserExists = func(string) bool { return true }
	for _, d := range stackFolders {
		p := filepath.Join(f.svr, "demo", d)
		if err := os.MkdirAll(p, 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, 0o750); err != nil {
			t.Fatal(err)
		}
	}
	f.installed = []record.Record{{Name: "demo", Version: "1.0.0"}}
}

func (f *planFixture) folder(name string) string {
	return filepath.Join(f.svr, "demo", name)
}

const okStep = "#!/bin/sh\ncase \"$1\" in plan) echo 'would: install demo'; echo 'changes: 1' ;; esac\n"

func TestPlanCleanFirstInstallListsEveryChangeAndWritesNothing(t *testing.T) {
	f := newPlanFixture(t, okStep)
	got := Plan(f.cfg, f.stack, nil)
	wantLines(t, got.Lines,
		"would: create system user stk-demo (no login)",
		"would: create "+f.folder("data")+" (owner stk-demo, mode 750)",
		"would: create "+f.folder("logs")+" (owner stk-demo, mode 750)",
		"would: create "+f.folder("config")+" (owner stk-demo, mode 750)",
		"would: create "+f.folder("backup")+" (owner stk-demo, mode 750)",
		"would: install demo",
		"would: write record "+filepath.Join(f.records, "demo"),
		"changes: 7",
	)
	if got.Changes != 7 || got.Blocked {
		t.Errorf("changes %d blocked %v; want 7 false", got.Changes, got.Blocked)
	}
	if _, err := os.Stat(filepath.Join(f.svr, "demo")); !os.IsNotExist(err) {
		t.Errorf("plan created the stack folder: %v", err)
	}
	if _, err := os.Stat(f.records); !os.IsNotExist(err) {
		t.Errorf("plan created the records folder: %v", err)
	}
}

func TestPlanSettledStackHasNoChanges(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'changes: 0'\n")
	f.settle(t)
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines, "changes: 0")
	if got.Changes != 0 || got.Blocked {
		t.Errorf("changes %d blocked %v; want 0 false", got.Changes, got.Blocked)
	}
}

func TestPlanWrongFolderModeIsCorrected(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'changes: 0'\n")
	f.settle(t)
	if err := os.Chmod(f.folder("data"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"would: correct "+f.folder("data")+" (mode 755 to 750)",
		"changes: 1",
	)
}

func TestPlanWrongOwnerIsCorrected(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'changes: 0'\n")
	f.settle(t)
	cur := f.stack.User
	f.stack.User = "stk-demo"
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"would: correct "+f.folder("data")+" (owner "+cur+" to stk-demo)",
		"would: correct "+f.folder("logs")+" (owner "+cur+" to stk-demo)",
		"would: correct "+f.folder("config")+" (owner "+cur+" to stk-demo)",
		"would: correct "+f.folder("backup")+" (owner "+cur+" to stk-demo)",
		"changes: 4",
	)
}

func TestPlanRecordedOlderVersionIsUpdated(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'changes: 0'\n")
	f.settle(t)
	f.installed = []record.Record{{Name: "demo", Version: "0.9.0"}}
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"would: update demo from 0.9.0 to 1.0.0",
		"changes: 1",
	)
}

func TestPlanMissingEnvValueBlocksWithExample(t *testing.T) {
	f := newPlanFixture(t, okStep)
	f.settle(t)
	if err := os.Remove(filepath.Join(f.envDir, "demo.env")); err != nil {
		t.Fatal(err)
	}
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"blocked: "+filepath.Join(f.envDir, "demo.env")+" is missing; it must hold: A",
		"example: A=changeme",
		"would: install demo",
		"changes: 1",
	)
	if !got.Blocked {
		t.Error("missing env value did not block")
	}
}

func TestPlanPortAndNASClashBlocks(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'changes: 0'\n")
	f.settle(t)
	f.installed = append(f.installed, record.Record{
		Name: "other", Version: "1.0.0", Ports: []int{18000}, NasPaths: []string{"/nas/demo"},
	})
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"blocked: demo wants port 18000, held by other",
		"blocked: demo wants NAS path /nas/demo, held by other",
		"changes: 0",
	)
	if !got.Blocked {
		t.Error("port clash did not block")
	}
}

func TestPlanStepExitingOneWithoutBlockedLineIsBlocked(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'error: disk full' >&2\necho 'more detail' >&2\nexit 1\n")
	f.settle(t)
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"blocked: install plan failed: error: disk full",
		"changes: 0",
	)
	if !got.Blocked {
		t.Error("failed step did not block")
	}
}

func TestPlanStepOwnBlockedLinePassesThrough(t *testing.T) {
	f := newPlanFixture(t, "#!/bin/sh\necho 'blocked: needs the NAS mounted'\nexit 1\n")
	f.settle(t)
	got := Plan(f.cfg, f.stack, f.installed)
	wantLines(t, got.Lines,
		"blocked: needs the NAS mounted",
		"changes: 0",
	)
}

func TestPlanUserLookupWithoutHookUsesOS(t *testing.T) {
	if !userExists(Config{}, "root") {
		t.Error("root should exist through os/user")
	}
	if userExists(Config{}, "no-such-user-for-plan-test") {
		t.Error("an absent user should not exist through os/user")
	}
}
