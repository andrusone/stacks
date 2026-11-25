package record

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func sample(name string) Record {
	return Record{
		Name:     name,
		Version:  "1.2.0",
		Commit:   "abc1234",
		Ports:    []int{8096, 8920},
		NasPaths: []string{"/mnt/media", "/mnt/backup"},
		Units:    []string{"plex.service", "plex-backup.timer"},
	}
}

func TestWriteThenReadBack(t *testing.T) {
	dir := t.TempDir()
	want := sample("plex")
	if err := Write(dir, want); err != nil {
		t.Fatal(err)
	}
	got, ok, err := Read(dir, "plex")
	if err != nil || !ok {
		t.Fatalf("Read: ok=%v err=%v", ok, err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("read back %+v, want %+v", got, want)
	}
}

func TestEmptyListsReadBackEmpty(t *testing.T) {
	dir := t.TempDir()
	if err := Write(dir, Record{Name: "bare", Version: "0.1"}); err != nil {
		t.Fatal(err)
	}
	got, ok, err := Read(dir, "bare")
	if err != nil || !ok {
		t.Fatalf("Read: ok=%v err=%v", ok, err)
	}
	if got.Ports != nil || got.NasPaths != nil || got.Units != nil {
		t.Fatalf("empty lists read back as %+v", got)
	}
}

func TestMissingRecordIsNotAnError(t *testing.T) {
	_, ok, err := Read(t.TempDir(), "nothere")
	if ok || err != nil {
		t.Fatalf("ok=%v err=%v, want false and no error", ok, err)
	}
}

func TestRewriteReplacesRecord(t *testing.T) {
	dir := t.TempDir()
	if err := Write(dir, sample("plex")); err != nil {
		t.Fatal(err)
	}
	newer := Record{Name: "plex", Version: "2.0.0", Ports: []int{9000}}
	if err := Write(dir, newer); err != nil {
		t.Fatal(err)
	}
	got, _, err := Read(dir, "plex")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, newer) {
		t.Fatalf("after rewrite got %+v, want %+v", got, newer)
	}
	left, _ := os.ReadDir(dir)
	if len(left) != 1 {
		t.Fatalf("rewrite left %d files, want 1 (no temporary file)", len(left))
	}
}

func TestListSortedByName(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"zeta", "alpha", "mid"} {
		if err := Write(dir, sample(n)); err != nil {
			t.Fatal(err)
		}
	}
	// A leftover temporary file from a failed write must not show up.
	if err := os.WriteFile(filepath.Join(dir, ".tmp-123"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, r := range got {
		names = append(names, r.Name)
	}
	if want := []string{"alpha", "mid", "zeta"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("List names %v, want %v", names, want)
	}
}

func TestListMissingFolderIsEmpty(t *testing.T) {
	got, err := List(filepath.Join(t.TempDir(), "nope"))
	if err != nil || len(got) != 0 {
		t.Fatalf("List missing folder: %v, %v; want none and no error", got, err)
	}
}

func TestBadNamesAreRefused(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"", "../escape", "a/b", ".hidden"} {
		if err := Write(dir, Record{Name: n}); err == nil {
			t.Errorf("Write name %q: no error", n)
		}
		if _, _, err := Read(dir, n); err == nil {
			t.Errorf("Read name %q: no error", n)
		}
	}
}

func TestPortClash(t *testing.T) {
	installed := []Record{{Name: "plex", Ports: []int{8096, 8920}}}
	candidate := Record{Name: "kometa", Ports: []int{8096}}
	got := Clash(candidate, installed)
	want := []string{"kometa wants port 8096, held by plex"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Clash = %q, want %q", got, want)
	}
}

func TestNasClash(t *testing.T) {
	installed := []Record{{Name: "plex", NasPaths: []string{"/mnt/media"}}}
	candidate := Record{Name: "backup", NasPaths: []string{"/mnt/media", "/mnt/other"}}
	got := Clash(candidate, installed)
	want := []string{"backup wants NAS path /mnt/media, held by plex"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Clash = %q, want %q", got, want)
	}
}

func TestNoClashWithItsOwnRecord(t *testing.T) {
	installed := []Record{{Name: "plex", Ports: []int{8096}, NasPaths: []string{"/mnt/media"}}}
	candidate := Record{Name: "plex", Version: "2.0", Ports: []int{8096}, NasPaths: []string{"/mnt/media"}}
	if got := Clash(candidate, installed); got != nil {
		t.Fatalf("Clash with own record = %q, want none", got)
	}
}

func TestNoClashWithStackThatIsNotInstalled(t *testing.T) {
	dir := t.TempDir()
	// "other" holds 8096 but has no record in the folder, so it is not installed.
	if err := Write(dir, Record{Name: "plex", Ports: []int{9000}}); err != nil {
		t.Fatal(err)
	}
	installed, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	candidate := Record{Name: "kometa", Ports: []int{8096}, NasPaths: []string{"/mnt/other"}}
	if got := Clash(candidate, installed); got != nil {
		t.Fatalf("Clash = %q, want none", got)
	}
}
