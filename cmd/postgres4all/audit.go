package main

import (
	"fmt"
	"strings"

	"github.com/Havoc24k/postgres4all/internal/audit"
	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/spf13/cobra"
)

func newAuditCmd() *cobra.Command {
	var cfgPath string
	var strict bool
	cmd := &cobra.Command{
		Use:   "audit",
		Short: "Report production-readiness gaps in the configured stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := config.Load(cfgPath)
			if err != nil {
				return err
			}
			findings := audit.Run(c)
			high := 0
			for _, fdg := range findings {
				fmt.Printf("[%-8s] %s\n    %s\n    fix: %s\n\n", strings.ToUpper(fdg.Severity), fdg.Title, fdg.Detail, fdg.Fix)
				if fdg.Severity == "high" {
					high++
				}
			}
			crit := audit.CriticalCount(findings)
			fmt.Printf("%d finding(s): %d critical, %d high.\n", len(findings), crit, high)

			fail := crit
			if strict {
				fail += high
			}
			if fail > 0 {
				return fmt.Errorf("not production-ready: %d blocking finding(s)", fail)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().BoolVar(&strict, "strict", false, "also fail on high-severity findings (for CI)")
	return cmd
}
