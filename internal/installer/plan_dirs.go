package installer

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"

	"stacks/internal/stack"
)

// stackFolders are the four folders each stack gets under SvrDir/<name> (SI-FR-07).
var stackFolders = []string{"data", "logs", "config", "backup"}

// folderMode is the mode of each stack folder (SI-FR-07).
const folderMode fs.FileMode = 0o750

// folderLines returns the would: or blocked: lines for the stack's four folders: a create when one is
// missing, a mode correction when the mode differs, and an owner correction when the run-as user exists
// and the folder is owned by someone else. A folder that cannot be read is blocked.
func folderLines(cfg Config, s stack.Stack, userKnown bool) []string {
	var out []string
	for _, name := range stackFolders {
		path := filepath.Join(cfg.SvrDir, s.Name, name)
		info, err := os.Stat(path)
		if errors.Is(err, fs.ErrNotExist) {
			out = append(out, fmt.Sprintf("would: create %s (owner %s, mode %03o)", path, s.User, folderMode))
			continue
		}
		if err != nil {
			out = append(out, fmt.Sprintf("blocked: cannot read %s: %v", path, err))
			continue
		}
		if perm := info.Mode().Perm(); perm != folderMode {
			out = append(out, fmt.Sprintf("would: correct %s (mode %03o to %03o)", path, perm, folderMode))
		}
		if userKnown {
			if owner := ownerName(info); owner != s.User {
				out = append(out, fmt.Sprintf("would: correct %s (owner %s to %s)", path, owner, s.User))
			}
		}
	}
	return out
}

// ownerName returns the owner's user name, or its number when the name is unknown.
func ownerName(info fs.FileInfo) string {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	id := strconv.FormatUint(uint64(st.Uid), 10)
	if u, err := user.LookupId(id); err == nil {
		return u.Username
	}
	return id
}
