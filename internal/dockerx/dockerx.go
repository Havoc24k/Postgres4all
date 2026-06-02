package dockerx

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

// Compose wraps `docker compose` for a generated build/ directory.
type Compose struct{ Dir string } // Dir holds build/ (contains .env + docker-compose.yml)

func (c Compose) baseArgs() []string {
	return []string{"compose", "--env-file", c.Dir + "/.env", "-f", c.Dir + "/docker-compose.yml"}
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
