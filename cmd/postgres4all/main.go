package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var version = "0.1.0-dev"

func main() {
	root := &cobra.Command{
		Use:           "postgres4all",
		Short:         "Provision a single Postgres that replaces your backend stack",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	// subcommands registered in later tasks
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
