package installer

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"stacks/internal/record"
	"stacks/internal/stack"
)

// checkFixture is a temp svr folder, records folder and stacks folder, with a
// fake unit table. Nothing real is read or run.
type checkFixture struct {
	t                    *testing.T
	svr, recs, stacksDir string
	states               map[string][2]bool // unit -> {enabled, active}; absent means both true
}

func newCheckFixture(t *testing.T) *checkFixture {
	t.Helper()
	root := t.TempDir()
	f := &checkFixture{t: t, svr: filepath.Join(root, "svr"), recs: filepath.Join(root, "records"),
		stacksDir: filepath.Join(root, "stacks"), states: map[string][2]bool{}}
	for _, d := range []string{f.svr, f.recs, f.stacksDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

func (f *checkFixture) cfg() CheckConfig {
	return CheckConfig{SvrDir: f.svr, RecordsDir: f.recs, UnitState: func(u string) (bool, bool) {
		st, ok := f.states[u]
		if !ok {
			return true, true
		}
		return st[0], st[1]
	}}
}

// addStack writes a stack folder with its four folders under svr. check is the
// check step's body after a bash shebang; "" writes no check file.
func (f *checkFixture) addStack(name, version, check string) stack.Stack {
	f.t.Helper()
	dir := filepath.Join(f.stacksDir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.t.Fatal(err)
	}
	if check != "" {
		if err := os.WriteFile(filepath.Join(dir, "check"), []byte("#!/usr/bin/env bash\n"+check+"\n"), 0o755); err != nil {
			f.t.Fatal(err)
		}
	}
	for _, d := range folders {
		if err := os.MkdirAll(filepath.Join(f.svr, name, d), 0o755); err != nil {
			f.t.Fatal(err)
		}
	}
	return stack.Stack{Name: name, Version: version, Units: []string{name + ".service"}, Dir: dir}
}

// writeRecord installs name at version, as the installer would.
func (f *checkFixture) writeRecord(name, version string) {
	f.t.Helper()
	if err := record.Write(f.recs, record.Record{Name: name, Version: version}); err != nil {
		f.t.Fatal(err)
	}
}

// wantCheck compares the lines and the NotOK flag.
func wantCheck(t *testing.T, got CheckResult, notOK bool, lines ...string) {
	t.Helper()
	if !reflect.DeepEqual(got.Lines, lines) || got.NotOK != notOK {
		t.Errorf("check\n got: %q NotOK=%v\nwant: %q NotOK=%v", got.Lines, got.NotOK, lines, notOK)
	}
}

func TestCheckOKStackWithPassingCheck(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), false, "demo: ok")
}

func TestCheckNothingInstalledSaysSoAndIgnoresFolders(t *testing.T) {
	f := newCheckFixture(t)
	f.addStack("demo", "1.0.0", "echo ok")
	if err := os.Mkdir(filepath.Join(f.svr, "stray"), 0o755); err != nil {
		t.Fatal(err)
	}
	wantCheck(t, Check(f.cfg(), nil, ""), false, "no stack is installed here")
}

func TestCheckVersionMismatch(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.1.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true,
		"demo: not ok: recorded v1.0.0, catalog v1.1.0; fix: setup-stacks.sh --stack demo --apply")
}

func TestCheckInactiveUnit(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	f.states["demo.service"] = [2]bool{true, false}
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true,
		"demo: not ok: unit demo.service is not active; fix: sudo systemctl enable --now demo.service")
}

func TestCheckDisabledUnit(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	f.states["demo.service"] = [2]bool{false, true}
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true,
		"demo: not ok: unit demo.service is not enabled; fix: sudo systemctl enable --now demo.service")
}

func TestCheckMissingFolderNamesIt(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	if err := os.Remove(filepath.Join(f.svr, "demo", "logs")); err != nil {
		t.Fatal(err)
	}
	want := "demo: not ok: folder " + filepath.Join(f.svr, "demo", "logs") +
		" is missing; fix: setup-stacks.sh --stack demo --apply"
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true, want)
}

func TestCheckFailingStepUsesItsOwnText(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", `echo "not ok: database is down; fix: sudo systemctl restart demo"; exit 1`)
	f.writeRecord("demo", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true,
		"demo: not ok: database is down; fix: sudo systemctl restart demo")
}

func TestCheckFailingStepWithNoTextNamesExitStatus(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "exit 3")
	f.writeRecord("demo", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), true,
		"demo: not ok: check step exited 3; fix: setup-stacks.sh --stack demo --apply")
}

func TestCheckOrphanHasNoFurtherChecks(t *testing.T) {
	f := newCheckFixture(t)
	f.writeRecord("gone", "1.0.0")
	wantCheck(t, Check(f.cfg(), nil, ""), false, "gone: orphaned")
}

func TestCheckStackWithNoCheckStepIsNotYetAndNotFailed(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "")
	f.writeRecord("demo", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), false, "demo: not yet: check step")
}

func TestCheckUnexpectedFoldersExceptLostFound(t *testing.T) {
	f := newCheckFixture(t)
	s := f.addStack("demo", "1.0.0", "echo ok")
	f.writeRecord("demo", "1.0.0")
	for _, d := range []string{"lost+found", "stray"} {
		if err := os.Mkdir(filepath.Join(f.svr, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(f.svr, "notes.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	wantCheck(t, Check(f.cfg(), []stack.Stack{s}, ""), false,
		"demo: ok",
		"not a stack folder: "+filepath.Join(f.svr, "notes.txt"),
		"not a stack folder: "+filepath.Join(f.svr, "stray"),
	)
}

func TestCheckNamesNotOKStacksInNameOrder(t *testing.T) {
	f := newCheckFixture(t)
	a := f.addStack("alpha", "1.0.0", "echo ok")
	b := f.addStack("beta", "2.0.0", "echo ok")
	f.writeRecord("beta", "1.0.0")
	f.writeRecord("alpha", "1.0.0")
	f.writeRecord("zed", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{b, a}, ""), true,
		"alpha: ok",
		"beta: not ok: recorded v1.0.0, catalog v2.0.0; fix: setup-stacks.sh --stack beta --apply",
		"zed: orphaned",
	)
}

func TestCheckOnlyInstalledStackGivesOneLine(t *testing.T) {
	f := newCheckFixture(t)
	a := f.addStack("alpha", "1.0.0", "echo ok")
	b := f.addStack("beta", "1.0.0", "echo ok")
	f.writeRecord("alpha", "1.0.0")
	f.writeRecord("beta", "1.0.0")
	if err := os.Mkdir(filepath.Join(f.svr, "stray"), 0o755); err != nil {
		t.Fatal(err)
	}
	wantCheck(t, Check(f.cfg(), []stack.Stack{a, b}, "beta"), false, "beta: ok")
}

func TestCheckOnlyNotInstalledSaysSo(t *testing.T) {
	f := newCheckFixture(t)
	a := f.addStack("alpha", "1.0.0", "echo ok")
	f.writeRecord("alpha", "1.0.0")
	wantCheck(t, Check(f.cfg(), []stack.Stack{a}, "nope"), false, "nope is not installed here")
}
