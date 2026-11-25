package installer

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"stacks/internal/stack"
)

// cleanInput returns a stack that needs keys A and B, with a complete env file, a clean clone and /svr mounted.
// Every path is in a temp folder, so nothing real is read.
func cleanInput(t *testing.T) BlockerInput {
	t.Helper()
	dir := t.TempDir()
	env := filepath.Join(dir, "demo.env")
	if err := os.WriteFile(env, []byte("A=1\nB=2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	clone := filepath.Join(dir, "clone")
	if err := exec.Command("git", "init", "-q", clone).Run(); err != nil {
		t.Fatal(err)
	}
	mounts := filepath.Join(dir, "mounts")
	if err := os.WriteFile(mounts, []byte("/dev/sdb1 /svr ext4 rw 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return BlockerInput{
		Stack:      stack.Stack{Name: "demo", Env: []string{"A", "B"}},
		EnvFile:    env,
		ExampleEnv: writeExample(t, dir, "A=\nB=\n"),
		CloneDir:   clone,
		SvrDir:     "/svr",
		MountsPath: mounts,
	}
}

func writeExample(t *testing.T, dir, content string) string {
	t.Helper()
	p := filepath.Join(dir, "example.env")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func wantLines(t *testing.T, got []string, want ...string) {
	t.Helper()
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("blockers\n got: %q\nwant: %q", got, want)
	}
}

func TestBlockersCleanInputHasNoLines(t *testing.T) {
	wantLines(t, Blockers(cleanInput(t)))
}

func TestBlockersMissingEnvFileNamesKeysAndExample(t *testing.T) {
	in := cleanInput(t)
	in.EnvFile = filepath.Join(t.TempDir(), "absent.env")
	wantLines(t, Blockers(in),
		"blocked: "+in.EnvFile+" is missing; it must hold: A, B",
		"example: A=\nB=",
	)
}

func TestBlockersEnvFileMissingOneKey(t *testing.T) {
	in := cleanInput(t)
	if err := os.WriteFile(in.EnvFile, []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wantLines(t, Blockers(in),
		"blocked: "+in.EnvFile+" has no value for: B",
		"example: A=\nB=",
	)
}

func TestBlockersEmptyValueCountsAsMissing(t *testing.T) {
	in := cleanInput(t)
	if err := os.WriteFile(in.EnvFile, []byte("A=1\nB=\n# B=2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	wantLines(t, Blockers(in),
		"blocked: "+in.EnvFile+" has no value for: B",
		"example: A=\nB=",
	)
}

func TestBlockersUnreadableExampleIsSkipped(t *testing.T) {
	in := cleanInput(t)
	in.EnvFile = filepath.Join(t.TempDir(), "absent.env")
	in.ExampleEnv = filepath.Join(t.TempDir(), "no-example.env")
	wantLines(t, Blockers(in), "blocked: "+in.EnvFile+" is missing; it must hold: A, B")
}

func TestBlockersDirtyCloneSaysToCommitOrDiscard(t *testing.T) {
	in := cleanInput(t)
	if err := os.WriteFile(filepath.Join(in.CloneDir, "new.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	wantLines(t, Blockers(in),
		"blocked: the stacks clone "+in.CloneDir+" has uncommitted changes; commit or discard them",
	)
}

func TestBlockersCloneThatIsNotARepoIsReported(t *testing.T) {
	in := cleanInput(t)
	in.CloneDir = t.TempDir()
	got := Blockers(in)
	if len(got) != 1 || !strings.HasPrefix(got[0], "blocked: cannot read the stacks clone "+in.CloneDir+": ") {
		t.Errorf("blockers %q, want one line that the clone cannot be read", got)
	}
}

func TestBlockersSvrNotMounted(t *testing.T) {
	in := cleanInput(t)
	if err := os.WriteFile(in.MountsPath, []byte("/dev/sdb1 /home ext4 rw 0 0\n/dev/sdb2 /svrx ext4 rw 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	wantLines(t, Blockers(in),
		"blocked: /svr is not a mounted filesystem; mount it first (this script never mounts or formats anything)",
	)
}

func TestBlockersSvrMountsFileMissingCountsAsNotMounted(t *testing.T) {
	in := cleanInput(t)
	in.MountsPath = filepath.Join(t.TempDir(), "absent")
	wantLines(t, Blockers(in),
		"blocked: /svr is not a mounted filesystem; mount it first (this script never mounts or formats anything)",
	)
}

func TestBlockersReportsAllInOrder(t *testing.T) {
	in := cleanInput(t)
	in.EnvFile = filepath.Join(t.TempDir(), "absent.env")
	if err := os.WriteFile(filepath.Join(in.CloneDir, "new.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(in.MountsPath, []byte("/dev/sdb1 /home ext4 rw 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := Blockers(in)
	if len(got) != 4 {
		t.Fatalf("got %d lines %q, want 4 (the env line, its example, the clone, the mount)", len(got), got)
	}
	if !strings.HasPrefix(got[0], "blocked: "+in.EnvFile+" is missing") || got[1] != "example: A=\nB=" ||
		!strings.Contains(got[2], "has uncommitted changes") || !strings.Contains(got[3], "/svr is not a mounted") {
		t.Errorf("order wrong: %q", got)
	}
}

func TestBlockersChangesNothingOnDisk(t *testing.T) {
	in := cleanInput(t)
	in.EnvFile = filepath.Join(t.TempDir(), "absent.env")
	if err := os.WriteFile(filepath.Join(in.CloneDir, "new.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	before := snapshot(t, filepath.Dir(in.EnvFile), in.CloneDir, filepath.Dir(in.MountsPath))
	Blockers(in)
	if after := snapshot(t, filepath.Dir(in.EnvFile), in.CloneDir, filepath.Dir(in.MountsPath)); !reflect.DeepEqual(before, after) {
		t.Errorf("files changed:\nbefore %q\nafter  %q", before, after)
	}
}

// snapshot lists every path under the given folders with its size, to show nothing was written.
func snapshot(t *testing.T, roots ...string) []string {
	t.Helper()
	var out []string
	for _, root := range roots {
		_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			out = append(out, p+" "+map[bool]string{true: "dir", false: "file"}[info.IsDir()])
			return nil
		})
	}
	return out
}
