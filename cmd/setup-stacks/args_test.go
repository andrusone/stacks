package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseArgsValid(t *testing.T) {
	cases := []struct {
		argv []string
		want args
	}{
		{nil, args{}},
		{[]string{"--help"}, args{Help: true}},
		{[]string{"--check"}, args{Check: true}},
		{[]string{"--stack", "alpha"}, args{Stack: "alpha"}},
		{[]string{"--stack", "alpha", "--apply"}, args{Stack: "alpha", Apply: true}},
		{[]string{"--apply", "--stack", "alpha"}, args{Stack: "alpha", Apply: true}},
		{[]string{"--stack", "alpha", "--check"}, args{Stack: "alpha", Check: true}},
	}
	for _, c := range cases {
		got, err := parseArgs(c.argv)
		if err != nil {
			t.Errorf("%q: error %v", c.argv, err)
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got %+v, want %+v", c.argv, got, c.want)
		}
	}
}

func TestParseArgsErrors(t *testing.T) {
	cases := []struct {
		argv []string
		want string
	}{
		{[]string{"--check", "--apply", "--stack", "a"}, "--check and --apply conflict: pick one"},
		{[]string{"--stack", "a", "--stack", "b"}, "--stack is given twice: pick one stack name"},
		{[]string{"--apply"}, "--apply needs --stack <name>"},
		{[]string{"--stack"}, "--stack needs a stack name after it"},
		{[]string{"--stack", "--check"}, "--stack needs a stack name after it"},
		{[]string{"--bogus"}, "unknown flag: --bogus"},
		{[]string{"stray"}, "unknown flag: stray"},
		{[]string{"--help", "--check"}, "--help is shown alone"},
		{[]string{"--help", "--stack", "a"}, "--help is shown alone"},
	}
	for _, c := range cases {
		got, err := parseArgs(c.argv)
		if err == nil {
			t.Errorf("%q: got %+v, want an error", c.argv, got)
			continue
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%q: error %q, want it to contain %q", c.argv, err, c.want)
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("%q: error %q spans lines", c.argv, err)
		}
	}
}
