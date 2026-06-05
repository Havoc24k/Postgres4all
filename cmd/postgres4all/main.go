package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var version = "1.4.0"

func main() {
	root := &cobra.Command{
		Use:           "postgres4all",
		Short:         "Provision a single Postgres that replaces your backend stack",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(newGenerateCmd())
	root.AddCommand(newInstallCmd())
	root.AddCommand(newUpdateCmd())
	root.AddCommand(newApplyFunctionsCmd())
	root.AddCommand(newAuditCmd())
	root.AddCommand(newMintTokenCmd())
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
