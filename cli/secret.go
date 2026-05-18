package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"

	"golang.org/x/crypto/bcrypt"
)

// runSecret is invoked as `sandboxctl secret <op> [args...]`. It's an
// internal helper consumed by sandbox.sh during `up`, not listed in the
// user-facing usage table.
//
// Operations:
//   bcrypt           hash the password read from stdin (avoids putting it
//                    on the command line where ps/argv would expose it).
//   rand <bytes>     write <bytes> of random data, hex-encoded, to stdout.
func runSecret(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl secret <bcrypt|rand> [args...]")
		return 2
	}
	switch args[0] {
	case "bcrypt":
		pw, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintln(os.Stderr, "secret bcrypt: read stdin:", err)
			return 1
		}
		// Trim a single trailing newline (echo "$pw" | sandboxctl …) but
		// leave any other whitespace intact in case it's a real password.
		if n := len(pw); n > 0 && pw[n-1] == '\n' {
			pw = pw[:n-1]
		}
		if len(pw) == 0 {
			fmt.Fprintln(os.Stderr, "secret bcrypt: empty password on stdin")
			return 2
		}
		hash, err := bcrypt.GenerateFromPassword(pw, 10)
		if err != nil {
			fmt.Fprintln(os.Stderr, "secret bcrypt:", err)
			return 1
		}
		fmt.Println(string(hash))
		return 0

	case "rand":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: sandboxctl secret rand <byte-count>")
			return 2
		}
		n, err := strconv.Atoi(args[1])
		if err != nil || n <= 0 || n > 1024 {
			fmt.Fprintln(os.Stderr, "secret rand: byte-count must be a positive integer ≤ 1024")
			return 2
		}
		buf := make([]byte, n)
		if _, err := rand.Read(buf); err != nil {
			fmt.Fprintln(os.Stderr, "secret rand:", err)
			return 1
		}
		fmt.Println(hex.EncodeToString(buf))
		return 0

	default:
		fmt.Fprintln(os.Stderr, "unknown secret op:", args[0])
		return 2
	}
}
