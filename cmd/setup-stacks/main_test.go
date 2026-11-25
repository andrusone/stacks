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

// The script is what the user runs, so its exit code must match run()'s: go run would turn 2 into 1.
func TestScriptPassesExitCode(t *testing.T) {
	cmd := exec.Command("bash", "../../setup-stacks.sh", "--apply")
	var errb bytes.Buffer
	cmd.Stderr = &errb
	err := cmd.Run()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 2 {
		t.Fatalf("script --apply: err %v, want exit 2", err)
	}
	if errb.String() != "error: not built yet\n" {
		t.Errorf("script stderr %q, want only the not-built line", errb.String())
	}
}

func TestOtherArgsNotBuilt(t *testing.T) {
	cases := [][]string{{}, {"--apply"}, {"--stack", "x"}, {"--help", "x"}, {"--check"}}
	for _, args := range cases {
		var out, errb bytes.Buffer
		if code := run(args, &out, &errb); code != 2 {
			t.Errorf("args %q: exit %d, want 2", args, code)
		}
		if errb.String() != "error: not built yet\n" {
			t.Errorf("args %q: stderr %q", args, errb.String())
		}
		if out.Len() != 0 {
			t.Errorf("args %q: stdout %q, want empty", args, out.String())
		}
	}
}
