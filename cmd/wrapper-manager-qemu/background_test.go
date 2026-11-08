package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBackgroundLogFiles(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), "background")
	t.Setenv("WRAPPER_MANAGER_LOG_PREFIX", prefix)
	closeLogs, err := backgroundLogs()
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintln(os.Stdout, "test stdout")
	fmt.Fprintln(os.Stderr, "test stderr")
	closeLogs()
	for _, suffix := range []string{"stdout", "stderr"} {
		data, err := os.ReadFile(prefix + "." + suffix + ".log")
		if err != nil || !strings.Contains(string(data), "test "+suffix) {
			t.Fatalf("missing direct %s log", suffix)
		}
	}
}

func TestGuestReceivesClosedInput(t *testing.T) {
	if os.Getenv("WRAPPER_TEST_GUEST") == "1" {
		return
	}
	t.Setenv("WRAPPER_TEST_GUEST", "1")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- runQemu([]string{exe, "-test.run=^TestGuestInputHelper$"}) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("guest waited for terminal input instead of receiving EOF")
	}
}

func TestGuestInputHelper(t *testing.T) {
	if os.Getenv("WRAPPER_TEST_GUEST") != "1" {
		return
	}
	buffer := make([]byte, 1)
	if count, err := os.Stdin.Read(buffer); count != 0 || err == nil {
		t.Fatal("guest input not closed")
	}
}
