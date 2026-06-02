package main

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newStub registers a command that is not yet ported to Go; it points users at the bash setup.sh.
func newStub(use, phase string) *cobra.Command {
	return &cobra.Command{
		Use:   use,
		Short: fmt.Sprintf("(%s — not yet ported; use ./setup.sh for now)", phase),
		RunE: func(cmd *cobra.Command, args []string) error {
			return fmt.Errorf("%q is implemented in %s of the Go port; for now use ./setup.sh %s", use, phase, use)
		},
	}
}
