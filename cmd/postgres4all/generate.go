package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/generate"
	"github.com/spf13/cobra"
)

func newGenerateCmd() *cobra.Command {
	var cfgPath, out string
	cmd := &cobra.Command{
		Use:   "generate",
		Short: "Generate the build/ directory from config.json (no Docker)",
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
			fmt.Printf("generated %s/ for: %v\n", out, enabledList(c))
			return nil
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().StringVar(&out, "out", "build", "output directory")
	return cmd
}

func enabledList(c *config.Config) []string {
	var e []string
	for _, k := range config.Order {
		if c.Enabled(k) {
			e = append(e, k)
		}
	}
	return e
}
