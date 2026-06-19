package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/storage"
)

const passwordEnv = "RELIQUARY_USER_PASSWORD"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "create-admin":
		err = create(os.Args[2:], auth.RoleAdmin)
	case "create-user":
		err = create(os.Args[2:], auth.RoleUser)
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		slog.Error("user command failed", "error", err)
		os.Exit(1)
	}
}

func create(args []string, role auth.Role) error {
	flags := flag.NewFlagSet("create-"+string(role), flag.ExitOnError)
	username := flags.String("username", "", "username to create")
	password := flags.String("password", "", "password to set; alternatively use "+passwordEnv)
	if err := flags.Parse(args); err != nil {
		return err
	}

	if *username == "" {
		return fmt.Errorf("--username is required")
	}
	if *password == "" {
		*password = os.Getenv(passwordEnv)
	}
	if *password == "" {
		return fmt.Errorf("--password or %s is required", passwordEnv)
	}

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	store, err := storage.New(cfg)
	if err != nil {
		return fmt.Errorf("connect to object storage: %w", err)
	}

	users := auth.NewUserStore(store)
	if err := users.Load(context.Background()); err != nil {
		return fmt.Errorf("load user store: %w", err)
	}
	if err := users.Create(context.Background(), *username, *password, role); err != nil {
		return fmt.Errorf("create %s %q: %w", role, *username, err)
	}
	if err := storage.NewFileIndex(store).Ensure(context.Background(), *username); err != nil {
		return fmt.Errorf("initialize file index for %q: %w", *username, err)
	}

	fmt.Printf("created %s user %q\n", role, *username)
	return nil
}

func usage() {
	fmt.Fprintf(
		os.Stderr,
		"usage:\n  reliquary-user create-admin --username USER [--password PASS]\n  reliquary-user create-user --username USER [--password PASS]\n\n%s can be used instead of --password.\n",
		passwordEnv,
	)
}
