package update

import (
	"strings"
	"testing"

	"github.com/Havoc24k/postgres4all/internal/config"
)

func target(caps ...string) *config.Config {
	c := &config.Config{Capabilities: map[string]bool{}}
	for _, k := range caps {
		c.Capabilities[k] = true
	}
	c.ApplyDefaults()
	return c
}

func TestDelta(t *testing.T) {
	cases := []struct {
		name             string
		tgt              []string
		installed        []string
		wantAdd, wantRem string
	}{
		{"add vector", []string{"document_store", "vector"}, []string{"document_store"}, "vector", ""},
		{"remove search", []string{"document_store"}, []string{"document_store", "search"}, "", "search"},
		{"add api+cap order", []string{"document_store", "search", "api"}, []string{"document_store"}, "search,api", ""},
		{"remove canonical", []string{"document_store"}, []string{"document_store", "search", "api"}, "", "search,api"},
		{"noop", []string{"document_store"}, []string{"document_store"}, "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			add, rem := Delta(target(tc.tgt...), tc.installed)
			if strings.Join(add, ",") != tc.wantAdd {
				t.Errorf("add: want %q got %q", tc.wantAdd, strings.Join(add, ","))
			}
			if strings.Join(rem, ",") != tc.wantRem {
				t.Errorf("rem: want %q got %q", tc.wantRem, strings.Join(rem, ","))
			}
		})
	}
}
