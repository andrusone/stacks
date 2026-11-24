package main

import (
	"bytes"
	"strings"
	"testing"
)

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
