package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
)

// Local desktop extension: preserve every login, while resource requests use
// only the account explicitly selected by the user's shortcut.
var activeAccount = struct {
	sync.RWMutex
	id string
}{}

var activeAccountPath = "data/active-account.json"

func activeAccountID() string {
	activeAccount.RLock()
	defer activeAccount.RUnlock()
	return activeAccount.id
}

func loadActiveAccount() error {
	data, err := os.ReadFile(activeAccountPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var saved struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(data, &saved); err != nil || saved.ID == "" {
		return fmt.Errorf("invalid saved active-account record")
	}
	activeAccount.Lock()
	activeAccount.id = saved.ID
	activeAccount.Unlock()
	return nil
}

func selectActiveAccount(id string) error {
	inst := GetInstance(id)
	if inst == nil || inst.Region == "" {
		return fmt.Errorf("account is not logged in")
	}
	data, err := json.Marshal(map[string]string{"id": id})
	if err != nil {
		return err
	}
	activeAccount.Lock()
	defer activeAccount.Unlock()
	temporary := activeAccountPath + ".tmp"
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return fmt.Errorf("cannot save account selection")
	}
	defer os.Remove(temporary)
	if err := os.Rename(temporary, activeAccountPath); err != nil {
		return fmt.Errorf("cannot save account selection")
	}
	activeAccount.id = id
	return nil
}

func routingInstances() []*WrapperInstance {
	all := SnapshotInstances()
	id := activeAccountID()
	if id == "" {
		return all
	}
	for _, inst := range all {
		if inst.Id == id {
			return []*WrapperInstance{inst}
		}
	}
	// An unavailable selected account must never silently use another account.
	return nil
}

func handleSelectAccount(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
			WriteLiteError(w, "JSON content type required")
			return
		}
		var req struct {
			Username string `json:"username"`
		}
		if err := decodeJSON(r, &req); err != nil || req.Username == "" {
			WriteLiteError(w, "missing username or invalid JSON")
			return
		}
		if err := selectActiveAccount(InstanceID(req.Username)); err != nil {
			WriteLiteError(w, err.Error())
			return
		}
	} else if r.Method != http.MethodGet {
		WriteLiteError(w, "method not allowed")
		return
	}
	id := activeAccountID()
	region := ""
	if inst := GetInstance(id); inst != nil {
		region = inst.Region
	}
	WriteLiteSuccess(w, map[string]any{"selected": id != "", "region": region})
}
