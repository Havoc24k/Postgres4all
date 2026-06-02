package main

import (
	"fmt"

	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/functions"
	"github.com/spf13/cobra"
)

func newApplyFunctionsCmd() *cobra.Command {
	var out, dir string
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "apply-functions",
		Short: "Apply functions/*.sql to a running install and reload PostgREST",
		RunE: func(cmd *cobra.Command, args []string) error {
			sql, n, err := functions.EmitSQL(dir)
			if err != nil {
				return err
			}
			if n == 0 {
				fmt.Printf("no functions to apply (%s/ has no .sql files).\n", dir)
				return nil
			}
			if dryRun {
				fmt.Print(sql)
				return nil
			}
			// live apply
			if err := dockerx.Preflight(); err != nil {
				return err
			}
			user := dockerx.EnvValue(out, "POSTGRES_USER")
			db := dockerx.EnvValue(out, "POSTGRES_DB")
			if user == "" || db == "" {
				return fmt.Errorf("%s/.env not found or missing POSTGRES_USER/POSTGRES_DB — run install first", out)
			}
			comp := dockerx.Compose{Dir: out}
			if vol, _ := comp.VolumeName(); !dockerx.VolumeExists(vol) {
				return fmt.Errorf("no existing install found (no pgdata volume); run 'postgres4all install' first")
			}
			// full stack up so the in-transaction NOTIFY reaches a live PostgREST
			if err := comp.Run("up", "-d", "--remove-orphans"); err != nil {
				return err
			}
			if err := comp.WaitHealthy(); err != nil {
				return err
			}
			fmt.Printf("applying %d function file(s)...\n", n)
			if err := comp.ApplySQL(user, db, sql); err != nil {
				return err
			}
			fmt.Println("functions applied; PostgREST schema reloaded (if running).")
			return nil
		},
	}
	cmd.Flags().StringVar(&out, "out", "build", "build directory")
	cmd.Flags().StringVar(&dir, "dir", "functions", "functions directory")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the SQL without applying")
	return cmd
}
