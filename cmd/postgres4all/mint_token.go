package main

import (
	"fmt"
	"time"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/dockerx"
	"github.com/Havoc24k/postgres4all/internal/jwt"
	"github.com/spf13/cobra"
)

func newMintTokenCmd() *cobra.Command {
	var cfgPath, out, sub, role, aud, ttlStr string
	cmd := &cobra.Command{
		Use:   "mint-token --sub <user>",
		Short: "Mint a short-lived HS256 JWT for the API (signed with the install's JWT_SECRET)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if sub == "" {
				return fmt.Errorf("--sub is required (the user identity for the token's sub claim)")
			}
			secret := dockerx.EnvValue(out, "JWT_SECRET")
			if secret == "" {
				return fmt.Errorf("no JWT_SECRET in %s/.env — run 'postgres4all install' first (the api capability must be enabled)", out)
			}

			// config is optional for minting; use it for jwt_audience / jwt_ttl defaults if present.
			ttl := 15 * time.Minute
			if c, err := config.Load(cfgPath); err == nil {
				ttl = c.TokenTTL()
				if aud == "" {
					aud = c.Security.JWTAudience
				}
			}
			if ttlStr != "" {
				d, err := time.ParseDuration(ttlStr)
				if err != nil {
					return fmt.Errorf("invalid --ttl %q: %w", ttlStr, err)
				}
				ttl = d
			}

			now := time.Now()
			claims := map[string]any{
				"role": role,
				"sub":  sub,
				"iat":  now.Unix(),
				"exp":  now.Add(ttl).Unix(),
			}
			if aud != "" {
				claims["aud"] = aud
			}
			tok, err := jwt.SignHS256(secret, claims)
			if err != nil {
				return err
			}
			fmt.Println(tok)
			return nil
		},
	}
	cmd.Flags().StringVar(&cfgPath, "config", "config.json", "config.json (for jwt_audience / jwt_ttl defaults)")
	cmd.Flags().StringVar(&out, "out", "build", "build directory (reads JWT_SECRET from <out>/.env)")
	cmd.Flags().StringVar(&sub, "sub", "", "subject / user identity for the sub claim (required)")
	cmd.Flags().StringVar(&role, "role", "authenticated", "PostgREST role claim")
	cmd.Flags().StringVar(&aud, "aud", "", "audience claim (overrides security.jwt_audience)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "", "token lifetime as a Go duration, e.g. 15m (overrides security.jwt_ttl)")
	return cmd
}
