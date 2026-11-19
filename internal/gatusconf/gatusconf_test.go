package gatusconf

import (
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"stacks/internal/healthfile"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata")

// The probes folder holds copies of the two OC8 test targets, probe-a and
// probe-b. probe-a has no needs.
func TestProbesGolden(t *testing.T) {
	golden(t, "testdata/probes", "testdata/probes.golden")
}

// The cases folder holds one stack with both expectations and one whose text
// has a single quote and a backslash, and one stack that needs the other.
func TestCasesGolden(t *testing.T) {
	golden(t, "testdata/cases", "testdata/cases.golden")
}

func golden(t *testing.T, dir, file string) {
	t.Helper()
	stacks, probs, err := healthfile.LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(probs) != 0 {
		t.Fatalf("fixture has problems: %v", probs)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if *update {
		if err := os.WriteFile(file, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Fatalf("output differs from %s (run go test -update to rewrite it)\n--- got ---\n%s", file, got)
	}
	again, err := Generate(stacks)
	if err != nil || again != got {
		t.Fatalf("second run differs from the first")
	}
}

// The output holds the two placeholders for the phone alert and no other topic.
func TestOnlyPlaceholderTopic(t *testing.T) {
	stacks, _, err := healthfile.LoadDir("testdata/probes")
	if err != nil {
		t.Fatal(err)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, `    url: "${NTFY_URL}"`) || !strings.Contains(got, `    topic: "${NTFY_TOPIC}"`) {
		t.Fatalf("placeholders missing:\n%s", got)
	}
	topic := regexp.MustCompile(`(?i)topic`)
	for _, line := range strings.Split(got, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if topic.MatchString(line) && strings.TrimSpace(line) != `topic: "${NTFY_TOPIC}"` {
			t.Fatalf("unexpected topic-like line: %q", line)
		}
	}
}

// A stack with no needs gets a comment in place of a dependencies endpoint.
func TestNoNeedsSaysSo(t *testing.T) {
	stacks, _, err := healthfile.LoadDir("testdata/probes")
	if err != nil {
		t.Fatal(err)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "# probe-a: no dependencies declared, so its dependencies answer is n/a") {
		t.Fatalf("no comment for probe-a's missing needs:\n%s", got)
	}
	// probe-b has the one dependencies endpoint; probe-a has none of its own.
	if n := len(dependencyName.FindAllString(got, -1)); n != 1 {
		t.Fatalf("want one dependencies endpoint (probe-b's), got %d", n)
	}
}

// Quotes and backslashes in the expected text are escaped, so they cannot end
// the YAML string early.
func TestTextIsEscaped(t *testing.T) {
	st := healthfile.Stack{
		ID: "q", Host: "q", Service: "q:1", Request: "http://q:1/",
		ExpectText: `say "hi" \o/`, HasText: true,
	}
	got, err := Generate([]healthfile.Stack{st})
	if err != nil {
		t.Fatal(err)
	}
	want := `      - "[BODY] == pat(*say \"hi\" \\o/*)"`
	if !strings.Contains(got, want) {
		t.Fatalf("want %s in:\n%s", want, got)
	}
}

// A needs entry that names no stack in the list is refused, not written.
func TestUnknownNeedIsRefused(t *testing.T) {
	st := healthfile.Stack{
		ID: "x", Host: "x", Service: "x:1", Request: "r", ExpectStatus: 200, HasStatus: true,
		Needs: []string{"nope"},
	}
	if _, err := Generate([]healthfile.Stack{st}); err == nil {
		t.Fatal("want an error for a need that is not a stack")
	}
}

var (
	dependencyName = regexp.MustCompile(`(?m)^  - name: "[^"]*: dependencies \(`)
	endpointLine   = regexp.MustCompile(`(?m)^  - name: (".*")\n    group: (".*")$`)
)

// synthetic is one health file built in a test: its ID and its needs.
type synthetic struct {
	id    string
	needs []string
}

// The ten stacks of the naming test. The IDs share no text with each other or
// with the answer names, so a search for one matches only what it should.
var tenStacks = []synthetic{
	{"alpha", nil},
	{"bravo", []string{"alpha"}},
	{"charlie", []string{"alpha", "bravo"}},
	{"delta", nil},
	{"echo", []string{"delta"}},
	{"foxtrot", []string{"echo", "alpha"}},
	{"golf", nil},
	{"hotel", []string{"golf"}},
	{"india", []string{"hotel", "delta"}},
	{"juliet", nil},
}

// Ten health files are written to a temp folder, generated, and the endpoint
// names read back from the output. Every name is unique and begins with its
// stack ID, every group is its stack ID, and a case-insensitive substring
// search (Gatus's search, HL-FR-01) returns exactly the endpoints the input
// implies. The expected names come from the input, not from the generator.
func TestNamesUniqueAndSearchable(t *testing.T) {
	dir := t.TempDir()
	var want []string
	for _, s := range tenStacks {
		src := "host = \"" + s.id + "\"\nservice = \"" + s.id + ":8080\"\nrequest = \"http://" + s.id + ":8080/\"\nexpect_status = 200\nneeds = ["
		for i, n := range s.needs {
			if i > 0 {
				src += ", "
			}
			src += "\"" + n + "\""
		}
		src += "]\n"
		if err := os.WriteFile(filepath.Join(dir, s.id+".toml"), []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
		want = append(want, s.id+": host", s.id+": service", s.id+": right answer")
		for _, n := range s.needs {
			want = append(want, s.id+": dependencies ("+n+")")
		}
	}

	stacks, probs, err := healthfile.LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(probs) != 0 {
		t.Fatalf("synthetic files have problems: %v", probs)
	}
	got, err := Generate(stacks)
	if err != nil {
		t.Fatal(err)
	}

	var names []string
	seen := map[string]bool{}
	for _, m := range endpointLine.FindAllStringSubmatch(got, -1) {
		name, err := strconv.Unquote(m[1])
		if err != nil {
			t.Fatal(err)
		}
		group, err := strconv.Unquote(m[2])
		if err != nil {
			t.Fatal(err)
		}
		if seen[name] {
			t.Fatalf("name %q is not unique", name)
		}
		seen[name] = true
		stack, _, _ := strings.Cut(name, ": ")
		if !strings.HasPrefix(name, stack+": ") || group != stack {
			t.Fatalf("name %q in group %q does not begin with its stack", name, group)
		}
		names = append(names, name)
	}
	sort.Strings(names)
	sort.Strings(want)
	if strings.Join(names, "\n") != strings.Join(want, "\n") {
		t.Fatalf("endpoints differ\n--- got ---\n%s\n--- want ---\n%s", strings.Join(names, "\n"), strings.Join(want, "\n"))
	}

	// Each query: a stack ID, an answer name, in both cases.
	queries := []string{"alpha", "BRAVO", "juliet", "host", "Service", "right answer", "DEPENDENCIES"}
	for _, q := range queries {
		var wantHits, gotHits []string
		for _, n := range want {
			if strings.Contains(strings.ToLower(n), strings.ToLower(q)) {
				wantHits = append(wantHits, n)
			}
		}
		for _, n := range names {
			if strings.Contains(strings.ToLower(n), strings.ToLower(q)) {
				gotHits = append(gotHits, n)
			}
		}
		sort.Strings(wantHits)
		sort.Strings(gotHits)
		if strings.Join(gotHits, "\n") != strings.Join(wantHits, "\n") {
			t.Fatalf("search %q returned\n%s\nwant\n%s", q, strings.Join(gotHits, "\n"), strings.Join(wantHits, "\n"))
		}
		if len(wantHits) == 0 {
			t.Fatalf("search %q expects no endpoints; the test would prove nothing", q)
		}
	}
}

// A DNS stack's right answer is a DNS query for its name, sent to its service,
// with a body condition on its address; the other endpoints are as before.
func TestDNSRightAnswer(t *testing.T) {
	src := "host = \"core-a\"\nservice = \"core-a:53\"\ndns_name = \"forge.core.example.test\"\ndns_expect = \"192.0.2.10\"\nneeds = []\n"
	st, probs := healthfile.Parse("core.toml", src)
	if len(probs) != 0 {
		t.Fatalf("fixture has problems: %v", probs)
	}
	got, err := Generate([]healthfile.Stack{st})
	if err != nil {
		t.Fatal(err)
	}
	want := "  - name: \"core: right answer\"\n" +
		"    group: \"core\"\n" +
		"    url: \"core-a:53\"\n" +
		"    dns:\n" +
		"      query-name: \"forge.core.example.test\"\n" +
		"      query-type: \"A\"\n" +
		"    interval: 10s\n" +
		"    conditions:\n" +
		"      - \"[BODY] == pat(*192.0.2.10*)\"\n"
	if !strings.Contains(got, want) {
		t.Fatalf("DNS endpoint missing:\n%s", got)
	}
	if strings.Count(got, "dns:") != 1 || strings.Contains(got, "[STATUS]") {
		t.Fatalf("only the right answer is DNS, with no status condition:\n%s", got)
	}
}
