package dockerx

import "testing"

func TestServiceNameDefaults(t *testing.T) {
	if got := (Compose{}).db(); got != "db" {
		t.Errorf("db() default: want db, got %q", got)
	}
	if got := (Compose{DBService: "postgres"}).db(); got != "postgres" {
		t.Errorf("db() override: want postgres, got %q", got)
	}
	if got := (Compose{}).pgrst(); got != "postgrest" {
		t.Errorf("pgrst() default: want postgrest, got %q", got)
	}
	if got := (Compose{PostgRESTService: "rest"}).pgrst(); got != "rest" {
		t.Errorf("pgrst() override: want rest, got %q", got)
	}
}
