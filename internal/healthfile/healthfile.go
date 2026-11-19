// Package healthfile reads the health files of the stacks repo (HL-FR-06): one
// TOML file per stack in the health folder, named for the stack ID. It checks
// them and never writes.
//
// The file is the subset of TOML the repo uses: comments, `key = value` lines,
// strings in double quotes (no escapes), integers, and one-line lists of such
// strings. Any other line is a problem with its line number. A problem with no
// line of its own (a missing key, a bad file name) is reported at line 1.
//
// A stack has one of two forms (CORE-FR-04): a request form, with request and
// an expectation (expect_status or expect_text), or a DNS form, with dns_name
// and dns_expect (an IP address the answer must contain) in place of request.
package healthfile

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Ext is the extension of a health file.
const Ext = ".toml"

var (
	idPattern  = regexp.MustCompile(`^[a-z0-9-]+$`)
	intPattern = regexp.MustCompile(`^[0-9]+$`)
)

// Problem is one thing wrong with a health file.
type Problem struct {
	File string // base name of the file
	Line int
	Msg  string
}

func (p Problem) String() string {
	return fmt.Sprintf("%s:%d: %s", p.File, p.Line, p.Msg)
}

// Stack is one parsed health file. Fields that the file did not set are zero.
// HasStatus and HasText say which expectation the file gave. A DNS stack has
// DNSName and DNSExpect set and no Request.
type Stack struct {
	ID           string
	Host         string
	Service      string
	Request      string
	DNSName      string
	DNSExpect    string
	ExpectStatus int
	ExpectText   string
	HasStatus    bool
	HasText      bool
	Needs        []string
	NeedsLine    int
}

// Parse reads the text of one health file named name. It returns the stack as
// far as it could read it, and every problem found in it.
func Parse(name, src string) (Stack, []Problem) {
	var st Stack
	var probs []Problem
	add := func(line int, format string, args ...any) {
		probs = append(probs, Problem{File: name, Line: line, Msg: fmt.Sprintf(format, args...)})
	}

	st.ID = strings.TrimSuffix(name, Ext)
	if !idPattern.MatchString(st.ID) {
		add(1, "file name %q is not a stack ID (lower-case letters, digits and -)", st.ID)
	}

	seen := map[string]bool{}
	for i, raw := range strings.Split(src, "\n") {
		lineNo := i + 1
		line := stripComment(strings.TrimSpace(strings.TrimRight(raw, "\r")))
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			add(lineNo, "want key = value")
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		switch key {
		case "host", "service", "request", "dns_name", "dns_expect", "expect_text", "expect_status", "needs":
		default:
			add(lineNo, "unknown key %q", key)
			continue
		}
		if seen[key] {
			add(lineNo, "%s is set twice", key)
			continue
		}
		seen[key] = true

		switch key {
		case "host":
			st.Host = stringValue(add, lineNo, key, val)
			if st.Host == "" && val == `""` {
				add(lineNo, "host: empty")
			}
		case "service":
			st.Service = stringValue(add, lineNo, key, val)
		case "request":
			st.Request = stringValue(add, lineNo, key, val)
		case "dns_name":
			st.DNSName = stringValue(add, lineNo, key, val)
			if st.DNSName == "" && val == `""` {
				add(lineNo, "dns_name: empty")
			}
		case "dns_expect":
			st.DNSExpect = stringValue(add, lineNo, key, val)
			if st.DNSExpect != "" && net.ParseIP(st.DNSExpect) == nil {
				add(lineNo, "dns_expect: want an IP address")
			}
		case "expect_text":
			st.ExpectText = stringValue(add, lineNo, key, val)
			st.HasText = true
		case "expect_status":
			if !intPattern.MatchString(val) {
				add(lineNo, "expect_status: want an integer")
				break
			}
			n, err := strconv.Atoi(val)
			if err != nil {
				add(lineNo, "expect_status: %v", err)
				break
			}
			st.ExpectStatus = n
			st.HasStatus = true
		case "needs":
			l, err := stringList(val)
			if err != nil {
				add(lineNo, "needs: %v", err)
				break
			}
			st.Needs = l
			st.NeedsLine = lineNo
		}
	}

	for _, k := range []string{"host", "service", "needs"} {
		if !seen[k] {
			add(1, "missing key %q", k)
		}
	}
	if seen["dns_name"] || seen["dns_expect"] {
		// The DNS form: exactly one form, and its own two keys.
		if seen["request"] {
			add(1, "request and dns_name are two forms: give one")
		}
		for _, k := range []string{"dns_name", "dns_expect"} {
			if !seen[k] {
				add(1, "missing key %q", k)
			}
		}
		if seen["expect_status"] || seen["expect_text"] {
			add(1, "expect_status and expect_text belong to request, not dns_name")
		}
	} else {
		if !seen["request"] {
			add(1, "missing key %q", "request")
		}
		if !seen["expect_status"] && !seen["expect_text"] {
			add(1, "needs expect_status or expect_text")
		}
	}
	sort.SliceStable(probs, func(i, j int) bool { return probs[i].Line < probs[j].Line })
	return st, probs
}

// stringValue reads a quoted string value. A bad value is reported and comes
// back empty.
func stringValue(add func(int, string, ...any), line int, key, val string) string {
	s, err := quoted(val)
	if err != nil {
		add(line, "%s: %v", key, err)
		return ""
	}
	return s
}

// LoadDir reads every *.toml file in dir. It returns the stacks in ID order,
// and every problem grouped by file in name order and by line within a file.
// A needs entry must name another file in dir. A stack with a problem is still
// returned as far as it could be read; callers decide whether problems stop them.
func LoadDir(dir string) ([]Stack, []Problem, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, err
	}
	var names []string
	ids := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), Ext) {
			continue
		}
		names = append(names, e.Name())
		ids[strings.TrimSuffix(e.Name(), Ext)] = true
	}

	var stacks []Stack
	var all []Problem
	for _, n := range names {
		src, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			return nil, nil, err
		}
		st, probs := Parse(n, string(src))
		for _, need := range st.Needs {
			if need == st.ID || !ids[need] {
				probs = append(probs, Problem{
					File: n,
					Line: st.NeedsLine,
					Msg:  fmt.Sprintf("needs %q: not another stack's file", need),
				})
			}
		}
		stacks = append(stacks, st)
		all = append(all, probs...)
	}
	sort.SliceStable(stacks, func(i, j int) bool { return stacks[i].ID < stacks[j].ID })
	return stacks, all, nil
}

// CheckDir checks every *.toml file in dir. It returns how many files have no
// problem, and every problem, grouped by file in name order and by line within
// a file. A needs entry must name another file in dir.
func CheckDir(dir string) (int, []Problem, error) {
	stacks, probs, err := LoadDir(dir)
	if err != nil {
		return 0, nil, err
	}
	bad := map[string]bool{}
	for _, p := range probs {
		bad[p.File] = true
	}
	ok := 0
	for _, st := range stacks {
		if !bad[st.ID+Ext] {
			ok++
		}
	}
	return ok, probs, nil
}

// stripComment removes a trailing # comment that is outside double quotes.
func stripComment(s string) string {
	inQuote := false
	for i, r := range s {
		switch {
		case r == '"':
			inQuote = !inQuote
		case r == '#' && !inQuote:
			return strings.TrimSpace(s[:i])
		}
	}
	return strings.TrimSpace(s)
}

// quoted returns the text of a double-quoted string. There are no escapes.
func quoted(v string) (string, error) {
	if len(v) < 2 || v[0] != '"' || v[len(v)-1] != '"' || strings.Contains(v[1:len(v)-1], `"`) {
		return "", errors.New("want a string in double quotes")
	}
	return v[1 : len(v)-1], nil
}

// stringList reads a one-line list of double-quoted strings, such as ["a", "b"]
// or []. It is empty when the brackets are empty.
func stringList(v string) ([]string, error) {
	if len(v) < 2 || v[0] != '[' || v[len(v)-1] != ']' {
		return nil, errors.New("want a list in square brackets")
	}
	inner := strings.TrimSpace(v[1 : len(v)-1])
	if inner == "" {
		return []string{}, nil
	}
	var out []string
	for _, part := range strings.Split(inner, ",") {
		s, err := quoted(strings.TrimSpace(part))
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}
