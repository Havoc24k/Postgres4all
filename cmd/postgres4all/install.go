package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/generate"
	"github.com/spf13/cobra"
)

func newInstallCmd() *cobra.Command {
	var cfgPath, out string
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Generate build/ and start the stack with docker compose",
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := config.Load(cfgPath)
			if err != nil {
				return err
			}
			if err := c.Validate(); err != nil {
				return err
			}
			if err := generate.Generate(c, out); err != nil {
				return err
			}
			if err := dockerx.Preflight(); err != nil {
				return err
			}
			comp := dockerx.Compose{Dir: out}
			if vol, _ := comp.VolumeName(); dockerx.VolumeExists(vol) {
				return fmt.Errorf("an install already exists (volume %s); use 'postgres4all update' (Phase 2) or 'docker compose -f %s/docker-compose.yml down -v' to start over", vol, out)
			}
			fmt.Println("starting stack...")
			return comp.Run("up", "--build")
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().StringVar(&out, "out", "build", "output directory")
	return cmd
}
