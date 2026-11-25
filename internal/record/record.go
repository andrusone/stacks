// Package record is the installed record (SI-FR-07, SI-FR-09): one small file
// per installed stack in a records folder the caller names (the real one is
// /var/lib/stacks), and the clash check that compares them. Nothing calls it
// yet. It is the record half only; the installer decides who may write the
// real folder.
package record

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
)

// Record is what the installer wrote when it installed a stack.
type Record struct {
	Name, Version, Commit string
	Ports                 []int
	NasPaths, Units       []string
}

// Write stores r as <dir>/<name> through a temporary file and a rename, so a
// failure never leaves a half record. The folder is created if it is missing.
func Write(dir string, r Record) error {
	if err := checkName(r.Name); err != nil {
		return err
	}
	text, err := format(r)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // harmless after a successful rename
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(dir, r.Name))
}

// Read returns the record called name in dir. The bool is false, with no
// error, when there is no such record.
func Read(dir, name string) (Record, bool, error) {
	if err := checkName(name); err != nil {
		return Record{}, false, err
	}
	data, err := os.ReadFile(filepath.Join(dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		return Record{}, false, nil
	}
	if err != nil {
		return Record{}, false, err
	}
	r, err := parse(string(data))
	if err != nil {
		return Record{}, false, fmt.Errorf("record %s: %w", name, err)
	}
	if r.Name != name {
		return Record{}, false, fmt.Errorf("record %s says it is %q", name, r.Name)
	}
	return r, true, nil
}

// List returns every record in dir, sorted by name. A missing folder has none.
// Hidden files, such as a temporary file left by a failed Write, are skipped.
func List(dir string) ([]Record, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Record
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		r, ok, err := Read(dir, e.Name())
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Clash returns one line per port or NAS path the candidate wants that an
// installed record holds. A record with the candidate's own name is ignored.
func Clash(candidate Record, installed []Record) []string {
	var out []string
	for _, other := range installed {
		if other.Name == candidate.Name {
			continue
		}
		for _, p := range candidate.Ports {
			if slices.Contains(other.Ports, p) {
				out = append(out, fmt.Sprintf("%s wants port %d, held by %s", candidate.Name, p, other.Name))
			}
		}
		for _, p := range candidate.NasPaths {
			if slices.Contains(other.NasPaths, p) {
				out = append(out, fmt.Sprintf("%s wants NAS path %s, held by %s", candidate.Name, p, other.Name))
			}
		}
	}
	return out
}

// checkName refuses a name that could leave the folder or clash with the
// hidden temporary files.
func checkName(name string) error {
	if name == "" || strings.HasPrefix(name, ".") || strings.ContainsAny(name, "/\\\n\r") {
		return fmt.Errorf("bad record name %q", name)
	}
	return nil
}

// format writes one key=value line per field. Lists are comma-separated, so a
// value that would break the line or split a list is refused rather than kept.
func format(r Record) (string, error) {
	scalars := map[string]string{"name": r.Name, "version": r.Version, "commit": r.Commit}
	for key, v := range scalars {
		if strings.ContainsAny(v, "\n\r") {
			return "", fmt.Errorf("record %s: %s has a line break", r.Name, key)
		}
	}
	ports := make([]string, 0, len(r.Ports))
	for _, p := range r.Ports {
		ports = append(ports, strconv.Itoa(p))
	}
	lists := map[string][]string{"nas": r.NasPaths, "units": r.Units}
	for key, items := range lists {
		for _, item := range items {
			if strings.ContainsAny(item, ",\n\r") {
				return "", fmt.Errorf("record %s: %s item %q has a comma or line break", r.Name, key, item)
			}
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "name=%s\n", r.Name)
	fmt.Fprintf(&b, "version=%s\n", r.Version)
	fmt.Fprintf(&b, "commit=%s\n", r.Commit)
	fmt.Fprintf(&b, "ports=%s\n", strings.Join(ports, ","))
	fmt.Fprintf(&b, "nas=%s\n", strings.Join(r.NasPaths, ","))
	fmt.Fprintf(&b, "units=%s\n", strings.Join(r.Units, ","))
	return b.String(), nil
}

// parse reads what format wrote. Unknown keys are ignored.
func parse(text string) (Record, error) {
	var r Record
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return Record{}, fmt.Errorf("line %q has no =", line)
		}
		var err error
		switch key {
		case "name":
			r.Name = val
		case "version":
			r.Version = val
		case "commit":
			r.Commit = val
		case "ports":
			r.Ports, err = parsePorts(val)
		case "nas":
			r.NasPaths = splitList(val)
		case "units":
			r.Units = splitList(val)
		}
		if err != nil {
			return Record{}, err
		}
	}
	return r, nil
}

func parsePorts(val string) ([]int, error) {
	var out []int
	for _, s := range splitList(val) {
		p, err := strconv.Atoi(s)
		if err != nil {
			return nil, fmt.Errorf("port %q is not a number", s)
		}
		out = append(out, p)
	}
	return out, nil
}

// splitList returns nil for an empty value, so a record with no ports, paths
// or units reads back the same as it was written.
func splitList(val string) []string {
	if val == "" {
		return nil
	}
	return strings.Split(val, ",")
}
