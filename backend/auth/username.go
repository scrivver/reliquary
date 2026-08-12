package auth

import "regexp"

// validUsername constrains any name that becomes a storage namespace. A
// username is interpolated directly into object keys — files/<username>/,
// thumbs/<username>/, indexes/<username>/files.json and
// <username>/checksums.json — so anything that could alter the resulting path
// (separators, dot segments, whitespace) has to be rejected before it is used.
var validUsername = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,64}$`)

// ValidUsername reports whether a username is safe to use as a storage
// namespace. It applies wherever an identity enters the system: local account
// creation, the proxy identity header, and the OIDC username claim.
//
// The pattern excludes "." and ".." implicitly — both are matched by the
// character class but are rejected here, since a bare dot segment collapses to
// a parent directory in any path-normalizing consumer.
func ValidUsername(username string) bool {
	if username == "." || username == ".." {
		return false
	}
	return validUsername.MatchString(username)
}
