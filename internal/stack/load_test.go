package stack

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// goodFields is a valid stack.toml, one field per line.
var goodFields = []string{
	`name = "qbt"`,
	`meaning = "download client"`,
	`version = "1.2.0"`,
	`user = "qbt"`,
	`units = ["qbt.service"]`,
	`ports = [8080, 6881]`,
	`nas_paths = ["/mnt/media"]`,
	`env = ["QBT_PASSWORD"]`,
}

// fieldsText joins the lines of goodFields, with the line for key replaced
// by replace (when given) and the line for key dropped when replace is "".
func fieldsText(key, replace string) string {
	var out []string
	for _, l := range goodFields {
		k, _, _ := strings.Cut(l, " =")
		if k != key {
			out = append(out, l)
		} else if replace != "" {
			out = append(out, replace)
		}
	}
	return strings.Join(out, "\n") + "\n"
}

// writeStack writes a stack.toml with text into <root>/<name>/.
func writeStack(t *testing.T, root, name, text string) {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// loadOnly loads root, expects one error and no stacks, and returns the error text.
func loadOnly(t *testing.T, root string) string {
	t.Helper()
	stacks, errs := Load(root)
	if len(stacks) != 0 {
		t.Fatalf("got %d stacks, want none: %+v", len(stacks), stacks)
	}
	if len(errs) != 1 {
		t.Fatalf("got %d errors, want 1: %v", len(errs), errs)
	}
	return errs[0].Error()
}

func TestLoadGoodStack(t *testing.T) {
	root := t.TempDir()
	writeStack(t, root, "qbt", fieldsText("", ""))

	stacks, errs := Load(root)
	if len(errs) != 0 {
		t.Fatalf("errors: %v", errs)
	}
	if len(stacks) != 1 {
		t.Fatalf("got %d stacks, want 1", len(stacks))
	}
	s := stacks[0]
	if s.Name != "qbt" || s.Meaning != "download client" || s.Version != "1.2.0" || s.User != "qbt" {
		t.Errorf("scalar fields: %+v", s)
	}
	if len(s.Units) != 1 || s.Units[0] != "qbt.service" {
		t.Errorf("units: %v", s.Units)
	}
	if len(s.Ports) != 2 || s.Ports[0] != 8080 || s.Ports[1] != 6881 {
		t.Errorf("ports: %v", s.Ports)
	}
	if len(s.NasPaths) != 1 || s.NasPaths[0] != "/mnt/media" {
		t.Errorf("nas_paths: %v", s.NasPaths)
	}
	if len(s.Env) != 1 || s.Env[0] != "QBT_PASSWORD" {
		t.Errorf("env: %v", s.Env)
	}
	if s.Dir != filepath.Join(root, "qbt") {
		t.Errorf("Dir = %q, want %q", s.Dir, filepath.Join(root, "qbt"))
	}
}

func TestLoadSortedAndEmptyListsAllowed(t *testing.T) {
	root := t.TempDir()
	writeStack(t, root, "zeta", fieldsText("name", `name = "zeta"`))
	writeStack(t, root, "alpha", strings.NewReplacer(
		`name = "qbt"`, `name = "alpha"`,
		`units = ["qbt.service"]`, `units = []`,
		`ports = [8080, 6881]`, `ports = []`,
		`nas_paths = ["/mnt/media"]`, `nas_paths = []`,
		`env = ["QBT_PASSWORD"]`, `env = []`,
	).Replace(fieldsText("", "")))

	stacks, errs := Load(root)
	if len(errs) != 0 {
		t.Fatalf("errors: %v", errs)
	}
	if len(stacks) != 2 || stacks[0].Name != "alpha" || stacks[1].Name != "zeta" {
		t.Fatalf("stacks not sorted by name: %+v", stacks)
	}
	if len(stacks[0].Units) != 0 || len(stacks[0].Ports) != 0 || len(stacks[0].Env) != 0 {
		t.Errorf("empty lists not kept empty: %+v", stacks[0])
	}
}

func TestLoadEmptyFolder(t *testing.T) {
	stacks, errs := Load(t.TempDir())
	if len(stacks) != 0 || len(errs) != 0 {
		t.Fatalf("got %v, %v; want nothing", stacks, errs)
	}
}

func TestLoadMissingFolder(t *testing.T) {
	stacks, errs := Load(filepath.Join(t.TempDir(), "nosuch"))
	if len(stacks) != 0 || len(errs) != 0 {
		t.Fatalf("got %v, %v; want nothing", stacks, errs)
	}
}

func TestLoadMissingField(t *testing.T) {
	for _, key := range required {
		t.Run(key, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "qbt", file)
			writeStack(t, root, "qbt", fieldsText(key, ""))

			got := loadOnly(t, root)
			want := path + `:1: missing required field "` + key + `"`
			if got != want {
				t.Errorf("got %q, want %q", got, want)
			}
		})
	}
}

func TestLoadWrongType(t *testing.T) {
	cases := map[string]string{
		"name":      `name = 7`,
		"meaning":   `meaning = ["x"]`,
		"version":   `version = 1.5`,
		"user":      `user = true`,
		"units":     `units = "qbt.service"`,
		"ports":     `ports = ["8080"]`,
		"nas_paths": `nas_paths = [1]`,
		"env":       `env = [["A"]]`,
	}
	for key, line := range cases {
		t.Run(key, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "qbt", file)
			writeStack(t, root, "qbt", fieldsText(key, line))

			got := loadOnly(t, root)
			if !strings.HasPrefix(got, path+":") || !strings.Contains(got, key) {
				t.Errorf("got %q, want the file, a line and %s", got, key)
			}
			// The line is the line of the key: fields are on lines 1-8 in order.
			wantLine := indexOf(key) + 1
			if !strings.HasPrefix(got, path+":"+strconv.Itoa(wantLine)+": ") {
				t.Errorf("got %q, want line %d", got, wantLine)
			}
		})
	}
}

func TestLoadParseError(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "qbt", file)
	// Line 6 is broken: the list has no comma and no closing bracket.
	writeStack(t, root, "qbt", fieldsText("ports", "ports = [8080 6881"))

	got := loadOnly(t, root)
	if !strings.HasPrefix(got, path+":6: ") {
		t.Errorf("got %q, want the file and line 6", got)
	}
}

// TestLoadParseErrorOnLine checks the line and a non-empty message for parse
// errors on line 2 (meaning): a missing value, and a string never closed.
func TestLoadParseErrorOnLine(t *testing.T) {
	cases := map[string]string{
		"missing value":   `meaning = `,
		"unclosed string": `meaning = "download client`,
	}
	for name, line := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "qbt", file)
			writeStack(t, root, "qbt", fieldsText("meaning", line))

			got := loadOnly(t, root)
			prefix := path + ":2: "
			if !strings.HasPrefix(got, prefix) {
				t.Fatalf("got %q, want prefix %q", got, prefix)
			}
			msg := strings.TrimPrefix(got, prefix)
			if msg == "" || strings.HasPrefix(msg, "toml:") {
				t.Errorf("message %q, want the library's text", msg)
			}
		})
	}
}

func TestLoadNameDiffersFromFolder(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "qbt", file)
	writeStack(t, root, "qbt", fieldsText("name", `name = "qbit"`))

	got := loadOnly(t, root)
	want := path + `:1: name "qbit" does not match its folder "qbt"`
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLoadFolderWithNoStackToml(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "bare"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := loadOnly(t, root)
	if want := filepath.Join(root, "bare") + ": no stack.toml"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLoadBadStackLeftOutOthersKept(t *testing.T) {
	root := t.TempDir()
	writeStack(t, root, "qbt", fieldsText("", ""))
	writeStack(t, root, "bad", fieldsText("env", ""))

	stacks, errs := Load(root)
	if len(stacks) != 1 || stacks[0].Name != "qbt" {
		t.Fatalf("stacks = %+v, want only qbt", stacks)
	}
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), `missing required field "env"`) {
		t.Fatalf("errors = %v, want one for bad's missing env", errs)
	}
}

// indexOf is the position of key in goodFields.
func indexOf(key string) int {
	for i, l := range goodFields {
		if k, _, _ := strings.Cut(l, " ="); k == key {
			return i
		}
	}
	return -1
}
