package installer

import (
	"bytes"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"stacks/internal/stack"
)

func TestStacksDir(t *testing.T) {
	if got := StacksDir("/x/stacks", "/home/u"); got != "/x/stacks" {
		t.Errorf("env set: got %q", got)
	}
	want := filepath.Join("/home/u", "src", "stacks", "stacks")
	if got := StacksDir("", "/home/u"); got != want {
		t.Errorf("env unset: got %q, want %q", got, want)
	}
}

func TestHelpWritesNothingElse(t *testing.T) {
	var b bytes.Buffer
	Help(&b, "/s", nil, nil)
	out := b.String()
	if !strings.HasSuffix(out, "no stacks yet: a stack is a folder with a stack.toml in /s\n") {
		t.Errorf("unexpected output:\n%s", out)
	}
	if n := strings.Count(out, "\n"); n != 6 {
		t.Errorf("want 6 lines, got %d:\n%s", n, out)
	}
}

func TestHelpListsStacksInNameOrder(t *testing.T) {
	var b bytes.Buffer
	stacks := []stack.Stack{
		{Name: "core", Meaning: "the core node"},
		{Name: "backup", Meaning: "nightly backup"},
		{Name: "monitor", Meaning: "watches the rest"},
	}
	Help(&b, "/s", stacks, nil)
	lines := strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
	if len(lines) != 5+3 {
		t.Fatalf("want 8 lines, got %d:\n%s", len(lines), b.String())
	}
	want := []string{"  backup  nightly backup", "  core  the core node", "  monitor  watches the rest"}
	for i, w := range want {
		if got := lines[5+i]; got != w {
			t.Errorf("stack line %d = %q, want %q", i, got, w)
		}
	}
	if strings.Contains(b.String(), "no stacks yet") {
		t.Errorf("the no-stacks line should be gone:\n%s", b.String())
	}
	if stacks[0].Name != "core" {
		t.Errorf("Help reordered the caller's slice")
	}
}

func TestHelpProblemsAfterStacks(t *testing.T) {
	var b bytes.Buffer
	stacks := []stack.Stack{{Name: "a", Meaning: "first"}}
	errs := []error{errors.New("/s/bad/stack.toml:2: missing required field \"name\"")}
	Help(&b, "/s", stacks, errs)
	lines := strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
	if len(lines) != 7 {
		t.Fatalf("want 7 lines, got %d:\n%s", len(lines), b.String())
	}
	if lines[5] != "  a  first" {
		t.Errorf("stack line = %q", lines[5])
	}
	if lines[6] != "problem: /s/bad/stack.toml:2: missing required field \"name\"" {
		t.Errorf("problem line = %q", lines[6])
	}
}

func TestHelpOnlyProblemsNoNoStacksLine(t *testing.T) {
	var b bytes.Buffer
	Help(&b, "/s", nil, []error{errors.New("boom")})
	out := b.String()
	if strings.Contains(out, "no stacks yet") {
		t.Errorf("errors but no stacks should not say none:\n%s", out)
	}
	if !strings.HasSuffix(out, "problem: boom\n") {
		t.Errorf("want the problem line last:\n%s", out)
	}
}
