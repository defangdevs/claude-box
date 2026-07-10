# VM test for issue #36: the per-user settings page lets an end user add and
# remove agent secrets through the browser (behind the same basic-auth as the
# terminal) without a nixos-rebuild and without typing the secret into the
# agent chat. Exercises:
#   - the claude-box-settings-<user> daemon unit (runs as the agent user),
#   - the Caddy /<user>/settings* route inside the basic-auth block,
#   - writing ~/.config/claude-box/env atomically at 0600,
#   - the page listing key NAMES only (never values),
#   - the agent unit's optional EnvironmentFile picking the file up on restart.
#
# Like the other tests, lib.mkForce-swaps the module Caddyfile for a minimal
# `tls internal` one (no ACME in the sandbox) that keeps the same
# cookie-or-basic-auth gate and reverse-proxies /agent/settings* to the
# settings daemon's unix socket (issue #49). Also asserts the socket's
# permission story: 0660 agent:caddy, other local users get EACCES, and
# nothing listens on TCP anymore.
{ claude-box }:
{
  name = "claude-box-settings-page";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ claude-box ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    # A second, unrelated local user: must NOT be able to reach agent's
    # settings daemon (issue #49).
    users.users.mallory = {
      isNormalUser = true;
    };
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

    # Minimal `tls internal` Caddyfile that keeps the settings route's auth
    # gate but proxies to the settings daemon's unix socket. Same env
    # placeholder the module wires up, so claude-web-auth-secrets still feeds
    # this vhost.
    services.caddy.configFile = lib.mkForce (pkgs.writeText "Caddyfile" ''
      box.test {
        log
        tls internal
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
    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("claude-box-settings-agent.service")
    client.wait_for_unit("multi-user.target")

    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # Daemon runs AS the agent user (no root).
    machine.succeed(
        "systemctl show claude-box-settings-agent --property=User | grep -x 'User=agent'"
    )

    # Issue #49: the daemon listens ONLY on the systemd-owned unix socket —
    # 0660 agent:caddy, no TCP listener for other local users to reach.
    machine.succeed(
        "stat -c '%U %G %a' /run/claude-box-settings/agent.sock | grep -x 'agent caddy 660'"
    )
    machine.fail("ss -tln | grep -q ':7781'")

    sock_curl = "curl -s --max-time 10 --unix-socket /run/claude-box-settings/agent.sock"

    # The owning user can talk to its own daemon over the socket...
    machine.succeed(
        f"su -s /bin/sh agent -c '{sock_curl} http://localhost/agent/settings/' "
        "| grep -q 'Settings for agent'"
    )
    # ...another local user gets permission denied — cannot list, write, or
    # restart. (Before the fix, all three worked over 127.0.0.1:7781.)
    machine.fail(
        f"su -s /bin/sh mallory -c '{sock_curl} http://localhost/agent/settings/'"
    )
    machine.fail(
        f"su -s /bin/sh mallory -c '{sock_curl} -d key=PWNED -d value=x "
        "http://localhost/agent/settings/set'"
    )
    machine.fail(
        f"su -s /bin/sh mallory -c '{sock_curl} -X POST http://localhost/agent/settings/restart'"
    )

    # Unauthenticated request to the settings path is rejected (401).
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' https://box.test/agent/settings/ | grep -x 401"
    )

    # Authenticated GET renders the page.
    client.succeed(
        f"{curl} -u agent:testpassword https://box.test/agent/settings/ "
        "| grep -q 'Settings for agent'"
    )

    # No env file exists yet.
    machine.fail("test -e /home/agent/.config/claude-box/env")

    # POST a secret through the page (never touches the terminal/chat).
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'key=GH_TOKEN&value=ghp_supersecret' "
        "https://box.test/agent/settings/set | grep -x 303"
    )

    # File written, owned by agent, mode 0600, with the value.
    machine.succeed(
        "stat -c '%U %a' /home/agent/.config/claude-box/env | grep -x 'agent 600'"
    )
    machine.succeed("grep -q '^GH_TOKEN=ghp_supersecret$' /home/agent/.config/claude-box/env")

    # The page lists the key NAME but NEVER the value.
    page = client.succeed(f"{curl} -u agent:testpassword https://box.test/agent/settings/")
    assert "GH_TOKEN" in page, "key name should be listed"
    assert "ghp_supersecret" not in page, "value must never be rendered"

    # Delete the key.
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'key=GH_TOKEN' https://box.test/agent/settings/delete | grep -x 303"
    )
    machine.fail("grep -q GH_TOKEN /home/agent/.config/claude-box/env")

    # The agent unit lists the user env file as an optional EnvironmentFile so
    # saved keys land in its environment after a restart — no rebuild.
    machine.succeed(
        "systemctl show claude-box-agent --property=EnvironmentFiles "
        "| grep -q '/home/agent/.config/claude-box/env'"
    )
  '';
}
