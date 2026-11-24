package installer

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
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
	Help(&b, "/s")
	out := b.String()
	if !strings.HasSuffix(out, "no stacks yet: a stack is a folder with a stack.toml in /s\n") {
		t.Errorf("unexpected output:\n%s", out)
	}
	if n := strings.Count(out, "\n"); n != 6 {
		t.Errorf("want 6 lines, got %d:\n%s", n, out)
	}
}
