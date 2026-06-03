package main

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/generate"
	"github.com/Havoc24k/postgres4all/internal/update"
	"github.com/spf13/cobra"
)

// splitCSV splits a comma-separated string into a slice, dropping empty entries.
func splitCSV(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func newUpdateCmd() *cobra.Command {
	var cfgPath, out, installed string
	var allowDrop, dryRun bool

	cmd := &cobra.Command{
		Use:   "update",
		Short: "Apply capability changes to an existing install (delta engine)",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Step 1: Load and validate config.
			c, err := config.Load(cfgPath)
			if err != nil {
				return err
			}
			if err := c.Validate(); err != nil {
				return err
			}

			// Step 2: Regenerate build/. Secrets are preserved inside generate.Generate (it reuses the
			// existing build/.env), so they survive regeneration without any config plumbing here.
			if err := generate.Generate(c, out); err != nil {
				return err
			}

			// Step 4: Determine installed capability set.
			// Guard: dry-run always requires --installed (check before touching Docker).
			if dryRun && !cmd.Flags().Changed("installed") {
				return fmt.Errorf("--dry-run requires --installed")
			}

			comp := dockerx.Compose{Dir: out, DBService: c.DBService(), PostgRESTService: c.PostgRESTService()}
			var installedList []string
			if cmd.Flags().Changed("installed") {
				installedList = splitCSV(installed)
			} else {
				// Live path: require Docker and an existing pgdata volume.
				if err := dockerx.Preflight(); err != nil {
					return err
				}
				vol, _ := comp.VolumeName()
				if !dockerx.VolumeExists(vol) {
					return fmt.Errorf("no existing install found (no pgdata volume); run 'postgres4all install' first")
				}
				if err := comp.UpDB(); err != nil {
					return err
				}
				if err := comp.WaitHealthy(); err != nil {
					return err
				}
				if !comp.HasMetaTable(c.Postgres.User, c.Postgres.DB) {
					return fmt.Errorf("not a managed install (no p4a_meta.capabilities)")
				}
				inst, _ := comp.QueryInstalled(c.Postgres.User, c.Postgres.DB)
				installedList = splitCSV(inst)
			}

			// Step 5: Compute delta and print the plan.
			add, remove := update.Delta(c, installedList)
			addStr := strings.Join(add, ", ")
			if addStr == "" {
				addStr = "(none)"
			}
			removeStr := strings.Join(remove, ", ")
			if removeStr == "" {
				removeStr = "(none)"
			}
			fmt.Println("Update plan:")
			fmt.Println("  ADD:", addStr)
			fmt.Println("  REMOVE:", removeStr)

			// Step 6: Guard destructive removals and no-op.
			if len(remove) > 0 && !allowDrop {
				return fmt.Errorf("removing capabilities (%s) is destructive; re-run with --allow-drop", strings.Join(remove, ", "))
			}
			if len(add) == 0 && len(remove) == 0 {
				fmt.Println("already up to date.")
				return nil
			}

			// Step 7: Read authPw AFTER Generate wrote build/.env.
			apiAdded := update.Contains(add, "api")
			authPw := dockerx.EnvValue(out, "AUTHENTICATOR_PASSWORD")
			user, db := c.Postgres.User, c.Postgres.DB

			// Step 8: Dry-run — print the three section headers unconditionally, gate only bodies.
			if dryRun {
				fmt.Println("===== PRE =====")
				if apiAdded {
					fmt.Print(update.EmitPreSQL(authPw))
				}
				fmt.Println("===== REMOVE =====")
				if len(remove) > 0 {
					fmt.Print(update.EmitRemoveSQL(c, remove))
				}
				fmt.Println("===== ADD =====")
				if len(add) > 0 {
					fmt.Print(update.EmitAddSQL(c, add, installedList))
				}
				return nil
			}

			// Step 9: Live phased execution.
			if err := comp.UpDB(); err != nil {
				return err
			}
			if err := comp.WaitHealthy(); err != nil {
				return err
			}
			if apiAdded {
				fmt.Println("phase 0: creating role chain...")
				if err := comp.ApplySQL(user, db, update.EmitPreSQL(authPw)); err != nil {
					return err
				}
			}
			if len(remove) > 0 {
				fmt.Println("phase 1: applying removals...")
				if err := comp.ApplySQL(user, db, update.EmitRemoveSQL(c, remove)); err != nil {
					return err
				}
			}
			fmt.Println("phase 2: rebuilding + recreating...")
			if err := comp.BuildUp(); err != nil {
				return err
			}
			if err := comp.WaitHealthy(); err != nil {
				return err
			}
			if len(add) > 0 {
				fmt.Println("phase 3: applying additions...")
				if err := comp.ApplySQL(user, db, update.EmitAddSQL(c, add, installedList)); err != nil {
					return err
				}
				if apiAdded {
					comp.RestartPostgrest()
				}
			}

			// Completion line: re-query with comma-SPACE + ORDER BY.
			out2, _ := exec.Command("docker", "compose", "--env-file", out+"/.env", "-f", out+"/docker-compose.yml",
				"exec", "-T", "db", "psql", "-tAqc", "SELECT string_agg(cap, ', ' ORDER BY cap) FROM p4a_meta.capabilities", "-U", user, "-d", db).Output()
			fmt.Printf("update complete. installed: %s\n", strings.TrimSpace(string(out2)))
			return nil
		},
	}

	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "path to config.json")
	cmd.Flags().StringVar(&out, "out", "build", "output directory")
	cmd.Flags().BoolVar(&allowDrop, "allow-drop", false, "allow removal of capabilities (destructive)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print SQL that would be applied without executing")
	cmd.Flags().StringVar(&installed, "installed", "", "comma-separated list of currently installed capabilities (for testing/dry-run)")
	return cmd
}
