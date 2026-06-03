package dockerx

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/Havoc24k/postgres4all/internal/generate"
)

// Compose wraps `docker compose` for a generated build/ directory.
type Compose struct {
	Dir              string // build/ (contains .env + docker-compose.yml)
	DBService        string // db service name (empty -> "db")
	PostgRESTService string // postgrest service name (empty -> "postgrest")
}

func (c Compose) baseArgs() []string {
	return []string{"compose", "--env-file", c.Dir + "/.env", "-f", c.Dir + "/docker-compose.yml"}
}

// db returns the db service name, defaulting to "db".
func (c Compose) db() string {
	if c.DBService != "" {
		return c.DBService
	}
	return "db"
}

// pgrst returns the postgrest service name, defaulting to "postgrest".
func (c Compose) pgrst() string {
	if c.PostgRESTService != "" {
		return c.PostgRESTService
	}
	return "postgrest"
}

// Run invokes `docker compose <baseArgs> <args...>` with streamed stdio.
func (c Compose) Run(args ...string) error {
	cmd := exec.Command("docker", append(c.baseArgs(), args...)...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
	return cmd.Run()
}

// VolumeName parses `docker compose config --format json` for the pgdata volume's real name
// (respects COMPOSE_PROJECT_NAME and the project directory).
func (c Compose) VolumeName() (string, error) {
	out, err := exec.Command("docker", append(c.baseArgs(), "config", "--format", "json")...).Output()
	if err != nil {
		return "", fmt.Errorf("docker compose config: %w", err)
	}
	var parsed struct {
		Volumes map[string]struct {
			Name string `json:"name"`
		} `json:"volumes"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return "", fmt.Errorf("parsing compose config: %w", err)
	}
	return parsed.Volumes["pgdata"].Name, nil
}

// VolumeExists reports whether a named Docker volume exists.
func VolumeExists(name string) bool {
	if name == "" {
		return false
	}
	return exec.Command("docker", "volume", "inspect", name).Run() == nil
}

// Preflight verifies docker + docker compose are available.
func Preflight() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("missing required tool: docker")
	}
	if exec.Command("docker", "compose", "version").Run() != nil {
		return fmt.Errorf("missing required tool: docker compose")
	}
	return nil
}

// ApplySQL pipes sql to `compose exec -T db psql -v ON_ERROR_STOP=1 --single-transaction -U user -d db`.
func (c Compose) ApplySQL(user, db, sql string) error {
	cmd := exec.Command("docker", append(c.baseArgs(), "exec", "-T", c.db(),
		"psql", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-U", user, "-d", db)...)
	cmd.Stdin = strings.NewReader(sql)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// QueryInstalled reads the comma-joined installed capability set from p4a_meta.capabilities.
func (c Compose) QueryInstalled(user, db string) (string, error) {
	out, err := exec.Command("docker", append(c.baseArgs(), "exec", "-T", c.db(),
		"psql", "-tAqc", "SELECT string_agg(cap, ',') FROM p4a_meta.capabilities", "-U", user, "-d", db)...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// HasMetaTable reports whether p4a_meta.capabilities exists.
func (c Compose) HasMetaTable(user, db string) bool {
	out, _ := exec.Command("docker", append(c.baseArgs(), "exec", "-T", c.db(),
		"psql", "-tAqc", "SELECT to_regclass('p4a_meta.capabilities')", "-U", user, "-d", db)...).Output()
	return strings.TrimSpace(string(out)) == "p4a_meta.capabilities"
}

// UpDB starts only the db service (no postgrest, whose role may not exist yet), clearing orphans.
func (c Compose) UpDB() error { return c.Run("up", "-d", "--remove-orphans", c.db()) }

// RestartPostgrest restarts the postgrest service (best-effort; no-op if absent).
func (c Compose) RestartPostgrest() { _ = c.Run("restart", c.pgrst()) }

// WaitHealthy polls the db container health for up to ~60s.
func (c Compose) WaitHealthy() error {
	for i := 0; i < 30; i++ {
		cid, _ := exec.Command("docker", append(c.baseArgs(), "ps", "-q", c.db())...).Output()
		id := strings.TrimSpace(string(cid))
		if id != "" {
			h, _ := exec.Command("docker", "inspect", "-f", "{{.State.Health.Status}}", id).Output()
			if strings.TrimSpace(string(h)) == "healthy" {
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("database did not become healthy")
}

// BuildUp: up -d --build --remove-orphans, with a DOCKER_BUILDKIT=0 legacy-build fallback for old buildx.
func (c Compose) BuildUp() error {
	cmd := exec.Command("docker", append(c.baseArgs(), "up", "-d", "--build", "--remove-orphans")...)
	var stderr strings.Builder
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderr) // stream live AND capture for buildx detection
	if err := cmd.Run(); err == nil {
		return nil
	} else if !strings.Contains(strings.ToLower(stderr.String()), "buildx") {
		return err // already streamed to os.Stderr
	}
	// fallback: legacy build then up --no-build
	bld := exec.Command("docker", "build", "-t", generate.GeneratedImage, c.Dir)
	bld.Env = append(os.Environ(), "DOCKER_BUILDKIT=0")
	bld.Stdout, bld.Stderr = os.Stdout, os.Stderr
	if err := bld.Run(); err != nil {
		return err
	}
	return c.Run("up", "-d", "--no-build", "--remove-orphans")
}

// EnvValue reads KEY=value from build/.env (Dir/.env).
func EnvValue(dir, key string) string {
	b, err := os.ReadFile(dir + "/.env")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok && k == key {
			return strings.TrimRight(v, "\r") // defensively strip a stray CR (CRLF .env)
		}
	}
	return ""
}
