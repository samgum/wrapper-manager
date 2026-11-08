package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setupActiveTest(t *testing.T) {
	t.Helper()
	originalID, originalPath := activeAccountID(), activeAccountPath
	activeAccount.Lock()
	activeAccount.id = ""
	activeAccount.Unlock()
	activeAccountPath = filepath.Join(t.TempDir(), "active.json")
	t.Cleanup(func() {
		activeAccount.Lock()
		activeAccount.id = originalID
		activeAccount.Unlock()
		activeAccountPath = originalPath
	})
}

func TestActiveAccountPinsRoutingAndStatus(t *testing.T) {
	setupActiveTest(t)
	jp, us := InstanceID("jp@example.invalid"), InstanceID("us@example.invalid")
	withInstances(t, map[string]string{jp: "jp", us: "us"}, func(_, _ string, _ bool) (songInfo, error) {
		return songInfo{available: true, hasLyrics: true}, nil
	})
	for _, id := range []string{jp, us, jp} {
		if err := selectActiveAccount(id); err != nil {
			t.Fatal(err)
		}
		for _, path := range []string{"/m3u8", "/key", "/lyrics", "/webplayback", "/license"} {
			ids, err := selectCandidates(path, "42")
			if err != nil || len(ids) != 1 || ids[0] != id {
				t.Fatalf("%s used wrong account", path)
			}
		}
		if len(SnapshotInstances()) != 2 {
			t.Fatal("switch removed an account")
		}
	}
	rr := httptest.NewRecorder()
	handleStatus(rr, httptest.NewRequest(http.MethodGet, "/status", nil))
	var status struct {
		Data struct {
			Regions []string `json:"regions"`
			Count   int      `json:"clientCount"`
			Saved   int      `json:"savedAccountCount"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Data.Count != 1 || status.Data.Saved != 2 || len(status.Data.Regions) != 1 || status.Data.Regions[0] != "jp" {
		t.Fatal("status did not reflect active account")
	}
	RemoveInstance(GetInstance(jp))
	ids, err := SelectInstances("42")
	if err != nil || len(ids) != 0 {
		t.Fatal("unavailable selected account fell back to a different account")
	}
}

func TestActiveAccountPersistenceAndInvalidSelection(t *testing.T) {
	setupActiveTest(t)
	withInstances(t, map[string]string{"one": "jp", "two": "us"}, nil)
	if err := selectActiveAccount("one"); err != nil {
		t.Fatal(err)
	}
	if err := selectActiveAccount("missing"); err == nil {
		t.Fatal("unknown account accepted")
	}
	if activeAccountID() != "one" {
		t.Fatal("failed switch changed selection")
	}
	activeAccount.Lock()
	activeAccount.id = ""
	activeAccount.Unlock()
	if err := loadActiveAccount(); err != nil || activeAccountID() != "one" {
		t.Fatal("restart did not restore selection")
	}
	activeAccountPath = filepath.Join(t.TempDir(), "missing", "active.json")
	if err := selectActiveAccount("two"); err == nil || activeAccountID() != "one" {
		t.Fatal("failed persistence changed active account")
	}
	activeAccountPath = filepath.Join(t.TempDir(), "corrupt.json")
	if err := os.WriteFile(activeAccountPath, []byte("bad JSON"), 0600); err != nil {
		t.Fatal(err)
	}
	if loadActiveAccount() == nil {
		t.Fatal("corrupt selection silently restored aggregate routing")
	}
}

func TestSelectAccountEndpoint(t *testing.T) {
	setupActiveTest(t)
	username := "test@example.invalid"
	withInstances(t, map[string]string{InstanceID(username): "jp"}, nil)
	for _, tc := range []struct {
		body, contentType string
		want              int
	}{
		{`{"username":"test@example.invalid"}`, "application/json", 0},
		{`{"username":"missing@example.invalid"}`, "application/json", -1},
		{`{"username":"test@example.invalid"}`, "text/plain", -1},
		{`{`, "application/json", -1},
	} {
		r := httptest.NewRequest(http.MethodPost, "/select-account", strings.NewReader(tc.body))
		r.Header.Set("Content-Type", tc.contentType)
		w := httptest.NewRecorder()
		handleSelectAccount(w, r)
		var response LiteReply
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || response.Code != tc.want {
			t.Fatal("unexpected selection response")
		}
	}
	if activeAccountID() != InstanceID(username) {
		t.Fatal("rejected request changed active account")
	}
}
