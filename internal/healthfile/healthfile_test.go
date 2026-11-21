package healthfile

import (
	"reflect"
	"testing"
)

// The good folder holds the two OC8 test targets, probe-a and probe-b.
func TestGoodFolderPasses(t *testing.T) {
	ok, probs, err := CheckDir("testdata/good")
	if err != nil {
		t.Fatal(err)
	}
	if ok != 2 || len(probs) != 0 {
		t.Fatalf("want 2 ok and no problems, got %d ok and %v", ok, probs)
	}
}

// Each failure folder must list exactly the problems below, as file:line: message.
func TestFailuresListExactly(t *testing.T) {
	cases := []struct {
		dir  string
		want []string
	}{
		{
			dir:  "testdata/missing-key",
			want: []string{`probe-b.toml:1: missing key "request"`},
		},
		{
			dir:  "testdata/no-needs",
			want: []string{`probe-b.toml:1: missing key "needs"`},
		},
		{
			dir:  "testdata/no-expect",
			want: []string{`probe-b.toml:1: needs expect_status or expect_text`},
		},
		{
			dir:  "testdata/unknown-key",
			want: []string{`probe-b.toml:5: unknown key "colour"`},
		},
		{
			dir:  "testdata/bad-need",
			want: []string{`probe-b.toml:4: needs "nope": not another stack's file`},
		},
		{
			dir:  "testdata/bad-name",
			want: []string{`Probe_B.toml:1: file name "Probe_B" is not a stack ID (lower-case letters, digits and -)`},
		},
		{
			dir:  "testdata/bad-line",
			want: []string{`probe-b.toml:5: want key = value`},
		},
		{
			dir:  "testdata/empty-host",
			want: []string{`probe-b.toml:2: host: empty`},
		},
		{
			dir:  "testdata/bad-insecure",
			want: []string{`probe-b.toml:6: insecure: want true or false`},
		},
	}
	for _, c := range cases {
		t.Run(c.dir, func(t *testing.T) {
			_, probs, err := CheckDir(c.dir)
			if err != nil {
				t.Fatal(err)
			}
			got := make([]string, 0, len(probs))
			for _, p := range probs {
				got = append(got, p.String())
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("problems:\n got  %q\n want %q", got, c.want)
			}
		})
	}
}

func TestParseReadsEveryPart(t *testing.T) {
	src := "host = \"h\"\nservice = \"h:8080\"\nrequest = \"http://h:8080/\"\nexpect_text = \"ok\"\nneeds = [\"a\", \"b\"]\n"
	st, probs := Parse("h.toml", src)
	if len(probs) != 0 {
		t.Fatalf("unexpected problems: %v", probs)
	}
	if st.ID != "h" || st.Host != "h" || st.Service != "h:8080" || st.Request != "http://h:8080/" {
		t.Fatalf("strings not read: %+v", st)
	}
	if !st.HasText || st.ExpectText != "ok" || st.HasStatus {
		t.Fatalf("expect_text not read: %+v", st)
	}
	if !reflect.DeepEqual(st.Needs, []string{"a", "b"}) || st.NeedsLine != 5 {
		t.Fatalf("needs not read: %v at line %d", st.Needs, st.NeedsLine)
	}
}

func TestEmptyNeedsIsAList(t *testing.T) {
	st, probs := Parse("x.toml", "host = \"x\"\nservice = \"x:1\"\nrequest = \"r\"\nexpect_status = 200\nneeds = []\n")
	if len(probs) != 0 {
		t.Fatalf("empty needs must be fine: %v", probs)
	}
	if st.Needs == nil || len(st.Needs) != 0 {
		t.Fatalf("want empty non-nil list, got %#v", st.Needs)
	}
}

// A DNS stack has dns_name and dns_expect in place of request, and no request.
func TestDNSFormParses(t *testing.T) {
	src := "host = \"core-a\"\nservice = \"core-a:53\"\ndns_name = \"forge.core.example.test\"\ndns_expect = \"192.0.2.10\"\nneeds = []\n"
	st, probs := Parse("core.toml", src)
	if len(probs) != 0 {
		t.Fatalf("unexpected problems: %v", probs)
	}
	if st.DNSName != "forge.core.example.test" || st.DNSExpect != "192.0.2.10" || st.Request != "" {
		t.Fatalf("dns form not read: %+v", st)
	}
}

// The forms are exclusive, and each form's keys are required.
func TestFormsListExactly(t *testing.T) {
	const head = "host = \"h\"\nservice = \"h:53\"\nneeds = []\n"
	cases := []struct {
		name string
		src  string
		want []string
	}{
		{
			name: "both forms",
			src:  head + "request = \"http://h/\"\nexpect_status = 200\ndns_name = \"a.test\"\ndns_expect = \"192.0.2.1\"\n",
			want: []string{
				"h.toml:1: request and dns_name are two forms: give one",
				"h.toml:1: expect_status and expect_text belong to request, not dns_name",
			},
		},
		{
			name: "neither form",
			src:  head + "expect_status = 200\n",
			want: []string{`h.toml:1: missing key "request"`},
		},
		{
			name: "dns without dns_expect",
			src:  head + "dns_name = \"a.test\"\n",
			want: []string{`h.toml:1: missing key "dns_expect"`},
		},
		{
			name: "dns_expect not an address",
			src:  head + "dns_name = \"a.test\"\ndns_expect = \"forge\"\n",
			want: []string{"h.toml:5: dns_expect: want an IP address"},
		},
		{
			name: "dns with expect_status",
			src:  head + "dns_name = \"a.test\"\ndns_expect = \"192.0.2.1\"\nexpect_status = 200\n",
			want: []string{"h.toml:1: expect_status and expect_text belong to request, not dns_name"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, probs := Parse("h.toml", c.src)
			got := make([]string, 0, len(probs))
			for _, p := range probs {
				got = append(got, p.String())
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("problems:\n got  %q\n want %q", got, c.want)
			}
		})
	}
}
