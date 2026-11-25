package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// writeStack makes <dir>/<name>/stack.toml with every required field.
func writeStack(t *testing.T, dir, name, meaning string) {
	t.Helper()
	folder := filepath.Join(dir, name)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	text := fmt.Sprintf(`name = %q
meaning = %q
version = "1"
user = "svc-%s"
units = ["%s.service"]
ports = [8080]
nas_paths = []
env = []
`, name, meaning, name, name)
	if err := os.WriteFile(filepath.Join(folder, "stack.toml"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func helpWith(t *testing.T, dir string) []string {
	t.Helper()
	t.Setenv("STACKS_DIR", dir)
	var out, errb bytes.Buffer
	if code := run([]string{"--help"}, &out, &errb); code != 0 {
		t.Fatalf("exit %d, want 0; stderr %q", code, errb.String())
	}
	if errb.Len() != 0 {
		t.Errorf("stderr %q, want empty", errb.String())
	}
	return strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
}

func TestHelpThreeStacksOneLineEach(t *testing.T) {
	dir := t.TempDir()
	writeStack(t, dir, "zeta", "last one")
	writeStack(t, dir, "alpha", "first one")
	writeStack(t, dir, "mid", "middle one")
	lines := helpWith(t, dir)
	if len(lines) != 5+3 {
		t.Fatalf("got %d lines, want 8:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	want := []string{"  alpha  first one", "  mid  middle one", "  zeta  last one"}
	for i, w := range want {
		if lines[5+i] != w {
			t.Errorf("line %d = %q, want %q", 5+i, lines[5+i], w)
		}
	}
	for _, l := range lines {
		if strings.Contains(l, "no stacks yet") {
			t.Errorf("no-stacks line should be gone: %q", l)
		}
	}
}

func TestHelpBrokenStackStillListsGoodOnes(t *testing.T) {
	dir := t.TempDir()
	writeStack(t, dir, "good", "works")
	writeStack(t, dir, "bad", "broken")
	// Break bad's stack.toml: a parse error on line 2.
	if err := os.WriteFile(filepath.Join(dir, "bad", "stack.toml"), []byte("name = \"bad\"\nmeaning = \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	lines := helpWith(t, dir)
	if len(lines) != 5+2 {
		t.Fatalf("got %d lines, want 7:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	if lines[5] != "  good  works" {
		t.Errorf("good stack line = %q", lines[5])
	}
	if !strings.HasPrefix(lines[6], "problem: ") || !strings.Contains(lines[6], filepath.Join(dir, "bad", "stack.toml")) {
		t.Errorf("problem line = %q, want it to name the broken file", lines[6])
	}
}

func TestHelpEmptyFolder(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("STACKS_DIR", dir)
	var out, errb bytes.Buffer
	if code := run([]string{"--help"}, &out, &errb); code != 0 {
		t.Fatalf("exit %d, want 0; stderr %q", code, errb.String())
	}
	if errb.Len() != 0 {
		t.Errorf("stderr %q, want empty", errb.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	wantPrefixes := []string{"  --help ", "  --stack <name> ", "  --apply ", "  --check "}
	if len(lines) != len(wantPrefixes)+2 {
		t.Fatalf("got %d lines, want %d:\n%s", len(lines), len(wantPrefixes)+2, out.String())
	}
	for i, p := range wantPrefixes {
		if !strings.HasPrefix(lines[i+1], p) {
			t.Errorf("line %d = %q, want prefix %q", i+1, lines[i+1], p)
		}
	}
	if last := lines[len(lines)-1]; !strings.Contains(last, "no stacks") || !strings.HasSuffix(last, dir) {
		t.Errorf("last line %q, want the no-stacks line ending in %q", last, dir)
	}
}

// listTree returns every path under dir with its size, so a test can see that nothing changed.
func listTree(t *testing.T, dir string) string {
	t.Helper()
	var b strings.Builder
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		fmt.Fprintf(&b, "%s %d %v\n", p, info.Size(), info.IsDir())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return b.String()
}

// runDir runs the command with dir as the stacks folder and a test env (testEnv) for every other path,
// and returns the exit code and both outputs.
func runDir(t *testing.T, dir string, argv ...string) (int, string, string) {
	t.Helper()
	e, _ := testEnv(t, dir)
	var out, errb bytes.Buffer
	code := runWith(argv, &out, &errb, e)
	return code, out.String(), errb.String()
}

func TestNoArgsListsAndStops(t *testing.T) {
	for _, withStack := range []bool{false, true} {
		dir := t.TempDir()
		if withStack {
			writeStack(t, dir, "alpha", "first one")
		}
		before := listTree(t, dir)
		code, out, errs := runDir(t, dir)
		if code != 1 {
			t.Errorf("stack=%v: exit %d, want 1", withStack, code)
		}
		lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
		if lines[0] != "no stack was named" {
			t.Errorf("stack=%v: first line %q, want the no-stack line", withStack, lines[0])
		}
		if lines[1] != "flags:" {
			t.Errorf("stack=%v: second line %q, want the help", withStack, lines[1])
		}
		if withStack && !strings.Contains(out, "  alpha  first one") {
			t.Errorf("stack=%v: help does not list alpha:\n%s", withStack, out)
		}
		if errs != "" {
			t.Errorf("stack=%v: stderr %q, want empty", withStack, errs)
		}
		if after := listTree(t, dir); after != before {
			t.Errorf("stack=%v: folder changed:\nbefore:\n%s\nafter:\n%s", withStack, before, after)
		}
	}
}

func TestUnknownStackListsAndStops(t *testing.T) {
	for _, withStack := range []bool{false, true} {
		dir := t.TempDir()
		if withStack {
			writeStack(t, dir, "alpha", "first one")
		}
		before := listTree(t, dir)
		for _, argv := range [][]string{{"--stack", "nosuch"}, {"--stack", "nosuch", "--check"}} {
			code, out, errs := runDir(t, dir, argv...)
			if code != 1 {
				t.Errorf("%q stack=%v: exit %d, want 1", argv, withStack, code)
			}
			lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
			if lines[0] != "unknown stack: nosuch" {
				t.Errorf("%q stack=%v: first line %q", argv, withStack, lines[0])
			}
			if lines[1] != "flags:" {
				t.Errorf("%q stack=%v: second line %q, want the help", argv, withStack, lines[1])
			}
			if withStack && !strings.Contains(out, "  alpha  first one") {
				t.Errorf("%q stack=%v: help does not list alpha:\n%s", argv, withStack, out)
			}
			if errs != "" {
				t.Errorf("%q stack=%v: stderr %q, want empty", argv, withStack, errs)
			}
		}
		if after := listTree(t, dir); after != before {
			t.Errorf("stack=%v: folder changed", withStack)
		}
	}
}

func TestConflictsExitTwoWithOneLine(t *testing.T) {
	cases := []struct {
		argv []string
		want string
	}{
		{[]string{"--check", "--apply", "--stack", "alpha"}, "--check and --apply conflict: pick one"},
		{[]string{"--stack", "alpha", "--stack", "alpha"}, "--stack is given twice"},
		{[]string{"--apply"}, "--apply needs --stack <name>"},
		{[]string{"--stack"}, "--stack needs a stack name"},
		{[]string{"--stack", "--apply"}, "--stack needs a stack name"},
		{[]string{"--bogus"}, "unknown flag: --bogus"},
		{[]string{"--help", "--apply", "--stack", "alpha"}, "--help is shown alone"},
	}
	dir := t.TempDir()
	writeStack(t, dir, "alpha", "first one")
	before := listTree(t, dir)
	for _, c := range cases {
		code, out, errs := runDir(t, dir, c.argv...)
		if code != 2 {
			t.Errorf("%q: exit %d, want 2", c.argv, code)
		}
		if out != "" {
			t.Errorf("%q: stdout %q, want empty", c.argv, out)
		}
		if n := strings.Count(errs, "\n"); n != 1 || !strings.HasPrefix(errs, "error: ") || !strings.Contains(errs, c.want) {
			t.Errorf("%q: stderr %q, want one error line containing %q", c.argv, errs, c.want)
		}
	}
	if after := listTree(t, dir); after != before {
		t.Errorf("folder changed")
	}
}

// --stack alone is the dry run now (dryrun_test.go); --apply and --check are still not built.
func TestApplyOrCheckNotBuilt(t *testing.T) {
	dir := t.TempDir()
	writeStack(t, dir, "alpha", "first one")
	for _, argv := range [][]string{{"--check"}, {"--stack", "alpha", "--apply"}, {"--stack", "alpha", "--check"}} {
		code, out, errs := runDir(t, dir, argv...)
		if code != 2 {
			t.Errorf("%q: exit %d, want 2", argv, code)
		}
		if errs != "error: not built yet\n" {
			t.Errorf("%q: stderr %q, want only the not-built line", argv, errs)
		}
		if out != "" {
			t.Errorf("%q: stdout %q, want empty", argv, out)
		}
	}
}

// The script is what the user runs, so its exit code must match run()'s: go run would turn 2 into 1.
func TestScriptPassesExitCode(t *testing.T) {
	cases := []struct {
		argv []string
		want string
	}{
		{[]string{"--check"}, "error: not built yet\n"},
		{[]string{"--apply"}, "--apply needs --stack <name>"},
	}
	for _, c := range cases {
		cmd := exec.Command("bash", append([]string{"../../setup-stacks.sh"}, c.argv...)...)
		var errb bytes.Buffer
		cmd.Stderr = &errb
		err := cmd.Run()
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || exitErr.ExitCode() != 2 {
			t.Fatalf("script %q: err %v, want exit 2", c.argv, err)
		}
		if !strings.Contains(errb.String(), c.want) {
			t.Errorf("script %q: stderr %q, want it to contain %q", c.argv, errb.String(), c.want)
		}
	}
}
