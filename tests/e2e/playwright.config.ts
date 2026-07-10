// Playwright config for the browser e2e tests (issue #36 settings page).
//
// These tests run against a LIVE claude-box web instance (a LAN rig or a
// deployed box) — they are not part of the sandboxed `nix flake check` VM
// tests. Point them at an instance with:
//
//   E2E_BASE_URL   e.g. https://192.168.1.88:62980  (required)
//   E2E_USER       terminal user name    (default: claude)
//   E2E_PASSWORD   that user's basic-auth password  (required)
//
// Optional on-box assertions (only when the runner executes on the box
// itself, as the same user):
//   E2E_ENV_FILE      path of the managed env file to inspect (mode/content)
//   E2E_TMUX_BIN      tmux binary — enables the restart-kills-session check
//   E2E_TMUX_SOCKET   tmux -L socket name   (default: agent-box)
//   E2E_TMUX_SESSION  tmux session name     (default: main)
//   E2E_TMUX_TMPDIR   TMUX_TMPDIR of the agent's socket
//
// Run with the nixpkgs runner (no npm install needed):
//   PLAYWRIGHT_BROWSERS_PATH=$(nix build --no-link --print-out-paths \
//     nixpkgs#playwright-driver.browsers) \
//   E2E_BASE_URL=... E2E_PASSWORD=... playwright test -c tests/e2e

import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  // The tests mutate one shared env file and one agent session — never run
  // them in parallel.
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    // Rigs and fresh boxes use `tls internal` / self-signed certs.
    ignoreHTTPSErrors: true,
    baseURL: process.env.E2E_BASE_URL,
  },
});
