package generate

import (
	"os"
	"path/filepath"
	"testing"
)

// The embedded capability fragments must stay byte-identical to init/capabilities/
// until the bash setup.sh is retired (single source of truth during the port).
func TestCapabilitiesInSyncWithInit(t *testing.T) {
	entries, err := capabilitiesFS.ReadDir("capabilities")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("no embedded capability fragments")
	}
	for _, e := range entries {
		name := e.Name()
		embedded, err := capabilitiesFS.ReadFile("capabilities/" + name)
		if err != nil {
			t.Fatal(err)
		}
		// repo root is two levels up from internal/generate
		onDisk, err := os.ReadFile(filepath.Join("..", "..", "init", "capabilities", name))
		if err != nil {
			t.Fatalf("init/capabilities/%s missing: %v", name, err)
		}
		if string(embedded) != string(onDisk) {
			t.Fatalf("embedded capabilities/%s differs from init/capabilities/%s — re-copy", name, name)
		}
	}
}
