//go:build cli

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// Headless harness for the core: `go run -tags cli . <dir>`.
// Prints events; stdin lines are JSON commands passed to call().
// `--logout <dir>` unlinks the device from the phone and wipes local data.
func main() {
	dir := "./.wa-cli"
	logout := false
	for _, a := range os.Args[1:] {
		if a == "--logout" {
			logout = true
		} else {
			dir = a
		}
	}
	if logout {
		sink = func([]byte) {}
		if _, err := start(dir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		deadline := time.Now().Add(30 * time.Second)
		for app.cli == nil || !app.cli.IsLoggedIn() {
			if time.Now().After(deadline) {
				fmt.Fprintln(os.Stderr, "not logged in (no session or can't connect)")
				os.Exit(1)
			}
			time.Sleep(200 * time.Millisecond)
		}
		if err := app.cli.Logout(app.ctx); err != nil {
			fmt.Fprintln(os.Stderr, "logout:", err)
			os.Exit(1)
		}
		app.wipeAppDB()
		fmt.Println("logged out; local data wiped")
		os.Exit(0)
	}
	sink = func(b []byte) { fmt.Println(string(b)) }
	if _, err := start(dir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		out, _ := json.Marshal(call([]byte(line)))
		fmt.Println(string(out))
	}
	select {}
}
