package stack

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// required are the fields every stack.toml must have, in the order the
// spec lists them.
var required = []string{"name", "meaning", "version", "user", "units", "ports", "nas_paths", "env"}

// Load reads <stacksDir>/<name>/stack.toml for every subfolder, sorted by
// name. A missing or empty stacksDir gives no stacks and no error. A stack
// with a problem is left out of the result and gives one error, which starts
// with the file path and the line.
func Load(stacksDir string) ([]Stack, []error) {
	entries, err := os.ReadDir(stacksDir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, []error{fmt.Errorf("%s:1: %w", stacksDir, err)}
	}
	var stacks []Stack
	var errs []error
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		s, err := loadOne(filepath.Join(stacksDir, e.Name()), e.Name())
		if err != nil {
			errs = append(errs, err)
			continue
		}
		stacks = append(stacks, s)
	}
	return stacks, errs
}

// loadOne reads and checks the stack.toml in dir, a folder named folder.
func loadOne(dir, folder string) (Stack, error) {
	path := filepath.Join(dir, file)
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Stack{}, fmt.Errorf("%s: no %s", dir, file)
	}
	if err != nil {
		return Stack{}, fmt.Errorf("%s:1: %w", path, err)
	}
	text := string(data)
	var raw map[string]any
	if _, err := toml.Decode(text, &raw); err != nil {
		var pe toml.ParseError
		if errors.As(err, &pe) {
			return Stack{}, fmt.Errorf("%s:%d: %s", path, pe.Position.Line, pe.Message)
		}
		return Stack{}, fmt.Errorf("%s:1: %w", path, err)
	}

	d := &decoder{path: path, lines: strings.Split(text, "\n"), raw: raw}
	for _, key := range required {
		if _, ok := raw[key]; !ok {
			return Stack{}, fmt.Errorf("%s:1: missing required field %q", path, key)
		}
	}
	s := Stack{Dir: dir}
	s.Name = d.str("name")
	if d.err == nil && s.Name != folder {
		d.fail("name", "name %q does not match its folder %q", s.Name, folder)
	}
	s.Meaning = d.str("meaning")
	s.Version = d.str("version")
	s.User = d.str("user")
	s.Units = d.strs("units")
	s.Ports = d.ints("ports")
	s.NasPaths = d.strs("nas_paths")
	s.Env = d.strs("env")
	if d.err != nil {
		return Stack{}, d.err
	}
	return s, nil
}

// decoder reads typed values from a parsed stack.toml. The first problem is
// kept in err and later reads return zero values, so one stack gives one error.
type decoder struct {
	path  string
	lines []string
	raw   map[string]any
	err   error
}

// fail records a problem on the line that defines key.
func (d *decoder) fail(key, format string, args ...any) {
	if d.err == nil {
		d.err = fmt.Errorf("%s:%d: %s", d.path, d.line(key), fmt.Sprintf(format, args...))
	}
}

// line finds the line of a top-level key. The library gives no positions for
// values, so this scans the text up to the first table header. It is 1 when
// the key is not found.
func (d *decoder) line(key string) int {
	for i, l := range d.lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "[") {
			break
		}
		if k, _, ok := strings.Cut(t, "="); ok && strings.Trim(strings.TrimSpace(k), `"'`) == key {
			return i + 1
		}
	}
	return 1
}

func (d *decoder) str(key string) string {
	if d.err != nil {
		return ""
	}
	v, ok := d.raw[key].(string)
	if !ok {
		d.fail(key, "%s must be a string", key)
	}
	return v
}

func (d *decoder) strs(key string) []string {
	if d.err != nil {
		return nil
	}
	items, ok := d.raw[key].([]any)
	out := make([]string, 0, len(items))
	for _, it := range items {
		s, isStr := it.(string)
		if !isStr {
			ok = false
			break
		}
		out = append(out, s)
	}
	if !ok {
		d.fail(key, "%s must be a list of strings", key)
		return nil
	}
	return out
}

func (d *decoder) ints(key string) []int {
	if d.err != nil {
		return nil
	}
	items, ok := d.raw[key].([]any)
	out := make([]int, 0, len(items))
	for _, it := range items {
		n, isInt := it.(int64)
		if !isInt {
			ok = false
			break
		}
		out = append(out, int(n))
	}
	if !ok {
		d.fail(key, "%s must be a list of integers", key)
		return nil
	}
	return out
}
