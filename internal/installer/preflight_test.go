package installer

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const ubuntu = "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"26.04\"\nPRETTY_NAME=\"Ubuntu 26.04 LTS\"\n"

// fixture returns a good env for a normal user: an Ubuntu 26.04 os-release file and a lock path in a temp folder.
func fixture(t *testing.T, osRelease string) PreflightEnv {
	t.Helper()
	dir := t.TempDir()
	rel := filepath.Join(dir, "os-release")
	if err := os.WriteFile(rel, []byte(osRelease), 0o644); err != nil {
		t.Fatal(err)
	}
	return PreflightEnv{UID: 1000, OSReleasePath: rel, LockPath: filepath.Join(dir, "lock")}
}

func wantErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("nil error, want %q", want)
	}
	if err.Error() != want {
		t.Errorf("error %q, want %q", err.Error(), want)
	}
	if strings.Contains(err.Error(), "\n") {
		t.Errorf("error is not one line: %q", err.Error())
	}
}

func TestPreflightRefusesRoot(t *testing.T) {
	env := fixture(t, ubuntu)
	env.UID = 0
	wantErr(t, Preflight(env), "error: run this as your normal user, not root; it calls sudo itself")
	if _, err := os.Stat(env.LockPath); !os.IsNotExist(err) {
		t.Errorf("root refusal took the lock: %v", err)
	}
}

func TestPreflightRefusesOtherOS(t *testing.T) {
	cases := map[string]string{
		"debian":       "ID=debian\nVERSION_ID=\"13\"\n",
		"ubuntu 24.04": "ID=ubuntu\nVERSION_ID=\"24.04\"\n",
		"no version":   "ID=ubuntu\n",
	}
	want := map[string]string{
		"debian":       "error: this runs only on Ubuntu 26.04 (found debian 13)",
		"ubuntu 24.04": "error: this runs only on Ubuntu 26.04 (found ubuntu 24.04)",
		"no version":   "error: this runs only on Ubuntu 26.04 (found ubuntu )",
	}
	for name, rel := range cases {
		env := fixture(t, rel)
		wantErr(t, Preflight(env), want[name])
		if _, err := os.Stat(env.LockPath); !os.IsNotExist(err) {
			t.Errorf("%s: refusal took the lock: %v", name, err)
		}
	}
}

func TestPreflightUnreadableOSRelease(t *testing.T) {
	env := fixture(t, ubuntu)
	missing := filepath.Join(filepath.Dir(env.LockPath), "nope")
	env.OSReleasePath = missing
	wantErr(t, Preflight(env), "error: cannot read "+missing+": open "+missing+": no such file or directory")
}

func TestPreflightGoodRunHoldsLock(t *testing.T) {
	env := fixture(t, ubuntu)
	if err := Preflight(env); err != nil {
		t.Fatalf("good run: %v", err)
	}
	data, err := os.ReadFile(env.LockPath)
	if err != nil {
		t.Fatalf("lock not written: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != strconv.Itoa(os.Getpid()) {
		t.Errorf("lock holds %q, want this pid %d", got, os.Getpid())
	}
	Release(env.LockPath)
	if _, err := os.Stat(env.LockPath); !os.IsNotExist(err) {
		t.Errorf("Release left the lock: %v", err)
	}
}

func TestPreflightHeldLock(t *testing.T) {
	env := fixture(t, ubuntu)
	if err := os.WriteFile(env.LockPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	want := "error: another setup-stacks run is in progress (pid " + strconv.Itoa(os.Getpid()) + ")"
	wantErr(t, Preflight(env), want)
	if data, _ := os.ReadFile(env.LockPath); strings.TrimSpace(string(data)) != strconv.Itoa(os.Getpid()) {
		t.Errorf("refusal changed the held lock: %q", data)
	}
}

// deadPid is a process id that was real and is now reaped, so nothing holds it.
func deadPid(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

func TestPreflightStaleLockIsTakenOver(t *testing.T) {
	env := fixture(t, ubuntu)
	pid := deadPid(t)
	if err := os.WriteFile(env.LockPath, []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Preflight(env); err != nil {
		t.Fatalf("stale lock should be taken over: %v", err)
	}
	if data, _ := os.ReadFile(env.LockPath); strings.TrimSpace(string(data)) != strconv.Itoa(os.Getpid()) {
		t.Errorf("lock holds %q after takeover, want this pid", data)
	}
	Release(env.LockPath)
}

func TestReleaseMissingLockIsQuiet(t *testing.T) {
	Release(filepath.Join(t.TempDir(), "never-made"))
}
