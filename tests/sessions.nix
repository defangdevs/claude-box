# VM test for issue #59: sessions are runtime data, decoupled from linux
# users. One hardened unit per USER supervises tmux sessions declared in the
# user-owned ~/.config/claude-box/sessions.json. Exercises:
#   - first-boot seeding of the Nix-declared config into sessions.json
#     (legacy per-user options standing in for a session named "main"),
#   - runtime session add/rm via the claude-box-session CLI — as the user,
#     no sudo, no nixos-rebuild,
#   - runtime-created sessions still living inside the hardened agent unit's
#     cgroup (the tmux server is a child of the supervisor),
#   - the supervisor recreating a killed listed session (restart semantics)
#     and NOT recreating a delisted one (destroy semantics),
#   - both agent CLIs installed regardless of what sessions run
#     (installAgents default),
#   - the settings daemon's session CRUD over HTTP (behind auth) and the
#     public names-only /<user>/sessions.json (no auth) that feeds the flat
#     picker,
#   - ttyd running with --url-arg so /<user>/?arg=<session> deep links work.
#
# Like the other tests, lib.mkForce-swaps the module Caddyfile for a minimal
# `tls internal` one (no ACME in the sandbox) that keeps the same routing
# shape: sessions.json outside the auth block, settings inside it.
{ claude-box }:
{
  name = "claude-box-sessions";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ claude-box ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
    services.claude-box = {
      enable = true;
      agent = "claude";
      users.agent = {
        web.passwordHashFile = "/var/lib/claude-box-web/password-hash";
      };
      web = {
        enable = true;
        domain = "box.test";
        user = "agent";
        fail2ban = false;
      };
    };
    system.stateVersion = "25.05";

    system.activationScripts.claude-web-password-hash.text = ''
      install -d -m 0700 /var/lib/claude-box-web
      if [ ! -s /var/lib/claude-box-web/password-hash ]; then
        (
          umask 077
          ${pkgs.caddy}/bin/caddy hash-password --plaintext testpassword \
            > /var/lib/claude-box-web/password-hash
        )
        chmod 0600 /var/lib/claude-box-web/password-hash
      fi
    '';

    services.caddy.configFile = lib.mkForce (pkgs.writeText "Caddyfile" ''
      box.test {
        log
        tls internal
        handle /agent/sessions.json {
          reverse_proxy unix//run/claude-box-settings/agent.sock
        }
        handle /agent/settings* {
          route {
            basic_auth bcrypt agent {
              agent {$WEB_PASSWORD_HASH_AGENT}
            }
            reverse_proxy unix//run/claude-box-settings/agent.sock
          }
        }
        handle {
          respond "ok" 200
        }
      }
    '');
  };

  nodes.client = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("claude-box-agent.service")
    machine.wait_for_unit("claude-box-settings-agent.service")
    machine.wait_for_unit("caddy.service")
    client.wait_for_unit("multi-user.target")

    def tmux(cmd):
        # Run a tmux command as the agent user against its own server (the
        # socket lives under the agent unit's RuntimeDirectory, not /tmp).
        return (
            "su -s /bin/sh agent -c 'env TMUX_TMPDIR=/run/agent-box-agent "
            "tmux -L agent-box " + cmd + "'"
        )

    # --- first boot: legacy options seeded a "main" session --------------
    machine.wait_until_succeeds(tmux("has-session -t =main"), timeout=120)
    machine.succeed(
        "stat -c '%U %a' /home/agent/.config/claude-box/sessions.json "
        "| grep -x 'agent 600'"
    )
    machine.succeed(
        "jq -e '.sessions.main.agent == \"claude\"' "
        "/home/agent/.config/claude-box/sessions.json"
    )

    # Both agent CLIs are installed even though no session uses codex yet
    # (installAgents defaults to all supported agents).
    machine.succeed("test -x /run/current-system/sw/bin/claude")
    machine.succeed("test -x /run/current-system/sw/bin/codex")

    # --- runtime add: no sudo, no rebuild ---------------------------------
    machine.succeed(
        "su -s /bin/sh agent -c 'claude-box-session add helper --agent codex'"
    )
    machine.wait_until_succeeds(tmux("has-session -t =helper"), timeout=60)
    machine.succeed(
        "jq -e '.sessions.helper.agent == \"codex\"' "
        "/home/agent/.config/claude-box/sessions.json"
    )

    # The runtime-created session runs INSIDE the hardened agent unit's
    # cgroup: the tmux server is a child of the supervisor, so systemd
    # sandboxing covers sessions added long after boot.
    server_pid = machine.succeed(tmux('display -p -t =helper "#{pid}"')).strip()
    machine.succeed(f"grep -q claude-box-agent.service /proc/{server_pid}/cgroup")

    # ls shows both sessions with their agents.
    listing = machine.succeed("su -s /bin/sh agent -c 'claude-box-session ls'")
    assert "main" in listing and "helper" in listing, listing
    assert "codex" in listing, listing

    # --- restart semantics: killed listed sessions come back --------------
    sid = machine.succeed(tmux('display -p -t =main "#{session_id}"')).strip()
    machine.succeed(tmux("kill-session -t =main"))
    machine.wait_until_succeeds(
        tmux('display -p -t =main "#{session_id}"') + f" | grep -vx '{sid}'",
        timeout=60,
    )

    # --- destroy semantics: delisted sessions stay gone -------------------
    machine.succeed("su -s /bin/sh agent -c 'claude-box-session rm helper'")
    machine.fail(tmux("has-session -t =helper"))
    machine.succeed("sleep 6")  # a few supervisor ticks
    machine.fail(tmux("has-session -t =helper"))
    machine.succeed(
        "jq -e '.sessions | has(\"helper\") | not' "
        "/home/agent/.config/claude-box/sessions.json"
    )

    # --- web surface -------------------------------------------------------
    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # Public names-only session list: 200 WITHOUT credentials, names+agents
    # only (never argv/cwd/env).
    sessions_json = client.succeed(f"{curl} https://box.test/agent/sessions.json")
    assert '"main"' in sessions_json, sessions_json
    assert "workingDirectory" not in sessions_json, sessions_json

    # The settings page (behind auth) can add a session...
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web&agent=claude' "
        "https://box.test/agent/settings/sessions/add | grep -x 303"
    )
    machine.wait_until_succeeds(tmux("has-session -t =web"), timeout=60)

    # ...and delete it again (delist + kill).
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web' "
        "https://box.test/agent/settings/sessions/delete | grep -x 303"
    )
    machine.succeed("sleep 6")
    machine.fail(tmux("has-session -t =web"))

    # Session CRUD is rejected without credentials.
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' "
        "-d 'name=pwn&agent=claude' "
        "https://box.test/agent/settings/sessions/add | grep -x 401"
    )

    # ttyd serves per-session deep links: the unit runs with --url-arg.
    machine.succeed("systemctl cat claude-web-terminal-agent | grep -q -- --url-arg")
  '';
}
