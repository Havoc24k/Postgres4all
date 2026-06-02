package update

import "github.com/Havoc24k/postgres4all/internal/config"

// Delta returns capabilities to add (in target, not installed) and remove (installed, not in target),
// both in canonical order.
func Delta(target *config.Config, installed []string) (add, remove []string) {
	inst := map[string]bool{}
	for _, c := range installed {
		if c != "" {
			inst[c] = true
		}
	}
	for _, c := range config.Order {
		t := target.Enabled(c)
		if t && !inst[c] {
			add = append(add, c)
		}
		if !t && inst[c] {
			remove = append(remove, c)
		}
	}
	return add, remove
}

// Contains reports membership; exported so update.go and emit.go can reuse it.
func Contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
