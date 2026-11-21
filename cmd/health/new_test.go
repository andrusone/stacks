package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"stacks/internal/healthfile"
)

// tempRepo makes a temp folder with a health folder copied from the real repo,
// so a new file is checked against the real siblings. It is removed by t.
func tempRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	dst := filepath.Join(root, "health")
	if err := os.Mkdir(dst, 0o755); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir("../../health")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join("../../health", e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dst, e.Name()), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func runNew(t *testing.T, root, stack, addr string, commit bool) (int, string, string) {
	t.Helper()
	var out, errw bytes.Buffer
	code := newStack(root, stack, addr, commit, &out, &errw)
	return code, out.String(), errw.String()
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestForgeFileWrittenAndValid(t *testing.T) {
	root := tempRepo(t)
	code, _, errs := runNew(t, root, "forge", "192.0.2.10", false)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, errs)
	}
	path := filepath.Join(root, "health", "forge.toml")
	st, probs := healthfile.Parse("forge.toml", mustRead(t, path))
	if len(probs) != 0 {
		t.Fatalf("written forge file has problems: %v", probs)
	}
	if st.Host != "192.0.2.10" || st.Service != "192.0.2.10:3000" || st.Request != "http://192.0.2.10:3000/" {
		t.Fatalf("forge host/service/request wrong: %+v", st)
	}
	if st.ExpectStatus != 200 || !st.HasStatus {
		t.Fatalf("forge expect_status wrong: %+v", st)
	}
	if len(st.Needs) != 0 {
		t.Fatalf("forge must need nothing, got %v", st.Needs)
	}
	if !strings.Contains(mustRead(t, path), "Soft dependency: the NAS") {
		t.Fatalf("forge file must name the NAS as soft")
	}
}

func TestRunnerNamesForgeAsHard(t *testing.T) {
	root := tempRepo(t)
	if code, _, errs := runNew(t, root, "forge", "192.0.2.10", false); code != 0 {
		t.Fatalf("forge: exit %d, stderr: %s", code, errs)
	}
	code, _, errs := runNew(t, root, "runner", "192.0.2.11", false)
	if code != 0 {
		t.Fatalf("runner: exit %d, stderr: %s", code, errs)
	}
	path := filepath.Join(root, "health", "runner.toml")
	src := mustRead(t, path)
	st, probs := healthfile.Parse("runner.toml", src)
	if len(probs) != 0 {
		t.Fatalf("written runner file has problems: %v", probs)
	}
	if len(st.Needs) != 1 || st.Needs[0] != "forge" {
		t.Fatalf("runner must need exactly forge, got %v", st.Needs)
	}
	if st.Service != "192.0.2.11:8081" || st.Request != "http://192.0.2.11:8081/" {
		t.Fatalf("runner service/request wrong: %+v", st)
	}
	if !strings.Contains(src, "Hard dependency: the forge") {
		t.Fatalf("runner file must name the forge as hard")
	}
}

func TestBadAddressWritesNothing(t *testing.T) {
	for _, addr := range []string{"example.test", "2001:db8::1", "::ffff:192.0.2.10", "192.0.2", "192.0.2.300", " 192.0.2.10"} {
		root := tempRepo(t)
		code, _, errs := runNew(t, root, "forge", addr, false)
		if code != 2 {
			t.Fatalf("%q: want exit 2, got %d", addr, code)
		}
		if !strings.Contains(errs, "not an IPv4 address") {
			t.Fatalf("%q: stderr %q does not refuse the address", addr, errs)
		}
		if _, err := os.Stat(filepath.Join(root, "health", "forge.toml")); !os.IsNotExist(err) {
			t.Fatalf("%q: a file was written", addr)
		}
	}
}

func TestExistingFileRefused(t *testing.T) {
	root := tempRepo(t)
	path := filepath.Join(root, "health", "forge.toml")
	const keep = "# hand-written, must survive\n"
	if err := os.WriteFile(path, []byte(keep), 0o644); err != nil {
		t.Fatal(err)
	}
	code, _, errs := runNew(t, root, "forge", "192.0.2.10", false)
	if code != 1 {
		t.Fatalf("want exit 1, got %d", code)
	}
	if !strings.Contains(errs, "already exists") {
		t.Fatalf("stderr %q does not say the file exists", errs)
	}
	if got := mustRead(t, path); got != keep {
		t.Fatalf("existing file was changed to %q", got)
	}
}

func TestFailedCheckRemovesFile(t *testing.T) {
	// A runner with no forge file: its needs entry names nothing, so the check fails.
	root := tempRepo(t)
	code, out, errs := runNew(t, root, "runner", "192.0.2.11", false)
	if code != 1 {
		t.Fatalf("want exit 1, got %d (stdout %q)", code, out)
	}
	if !strings.Contains(out, `runner.toml:`) || !strings.Contains(out, `needs "forge"`) {
		t.Fatalf("stdout %q does not name the failing need", out)
	}
	if !strings.Contains(errs, "removed") {
		t.Fatalf("stderr %q does not say the file was removed", errs)
	}
	if _, err := os.Stat(filepath.Join(root, "health", "runner.toml")); !os.IsNotExist(err) {
		t.Fatalf("runner.toml was left behind after the check failed")
	}
}

func TestCommitMakesOneCommit(t *testing.T) {
	for _, kv := range [][2]string{
		{"GIT_AUTHOR_NAME", "test"}, {"GIT_AUTHOR_EMAIL", "test@example.invalid"},
		{"GIT_COMMITTER_NAME", "test"}, {"GIT_COMMITTER_EMAIL", "test@example.invalid"},
	} {
		t.Setenv(kv[0], kv[1])
	}
	root := tempRepo(t)
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, b)
		}
		return strings.TrimSpace(string(b))
	}
	git("init", "-q")
	git("add", "health")
	git("commit", "-q", "-m", "base")
	before := git("rev-list", "--count", "HEAD")

	// An unrelated staged file must stay staged and out of the commit.
	if err := os.WriteFile(filepath.Join(root, "other.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", "other.txt")

	code, _, errs := runNew(t, root, "forge", "192.0.2.10", true)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, errs)
	}
	if after := git("rev-list", "--count", "HEAD"); after != strconv.Itoa(mustAtoi(t, before)+1) {
		t.Fatalf("want exactly one new commit, count %s -> %s", before, after)
	}
	if subj := git("log", "-1", "--format=%s"); subj != "health: add forge at 192.0.2.10" {
		t.Fatalf("commit subject %q", subj)
	}
	if files := git("show", "--name-only", "--format=", "HEAD"); files != "health/forge.toml" {
		t.Fatalf("commit files %q, want only health/forge.toml", files)
	}
	if staged := git("diff", "--cached", "--name-only"); staged != "other.txt" {
		t.Fatalf("unrelated staged file changed: %q", staged)
	}
}

func mustAtoi(t *testing.T, s string) int {
	t.Helper()
	n, err := strconv.Atoi(s)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{
		{},
		{"forge"},
		{"monitor", "192.0.2.10"},
		{"forge", "192.0.2.10", "extra"},
	} {
		var out, errw bytes.Buffer
		if code := newCommand(args, &out, &errw); code != 2 {
			t.Fatalf("args %v: want exit 2, got %d", args, code)
		}
	}
}
