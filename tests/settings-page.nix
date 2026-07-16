# VM test for issue #36: the per-user settings page lets an end user add and
# remove agent secrets through the browser (behind the same basic-auth as the
# terminal) without a nixos-rebuild and without typing the secret into the
# agent chat. Exercises:
#   - the agent-box-settings-<user> daemon unit (runs as the agent user),
#   - the Caddy /<user>/settings* route inside the basic-auth block,
#   - writing ~/.config/agent-box/env atomically at 0600,
#   - the page listing key NAMES only (never values),
#   - the agent unit's optional EnvironmentFile picking the file up on restart.
#
# Like the other tests, lib.mkForce-swaps the module Caddyfile for a minimal
# `tls internal` one (no ACME in the sandbox) that keeps the same
# cookie-or-basic-auth gate and reverse-proxies /agent/settings* to the
# settings daemon's unix socket (issue #49). Also asserts the socket's
# permission story: 0660 agent:caddy, other local users get EACCES, and
# nothing listens on TCP anymore.
{ agent-box }:
{
  name = "agent-box-settings-page";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ agent-box ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    # A second, unrelated local user: must NOT be able to reach agent's
    # settings daemon (issue #49).
    users.users.mallory = {
      isNormalUser = true;
    };
    services.agent-box = {
      enable = true;
      agent = "claude";
      users.agent = {
        web.passwordHashFile = "/var/lib/agent-box-web/password-hash";
      };
      web = {
        enable = true;
        domain = "box.test";
        user = "agent";
        fail2ban = false;
      };
      # Issue 54: the settings page grows an "Update box" button that triggers
      # agent-box-update.service through the allowlisted sudo rule. The VM has
      # no network, so the unit itself will fail after activating — the test
      # only proves the trigger plumbing (button -> daemon -> sudo -> unit).
      selfUpdate = {
        enable = true;
        rev = "0000000000000000000000000000000000000000";
      };
    };
    system.stateVersion = "25.05";

    system.activationScripts.agent-web-password-hash.text = ''
      install -d -m 0700 /var/lib/agent-box-web
      if [ ! -s /var/lib/agent-box-web/password-hash ]; then
        (
          umask 077
          ${pkgs.caddy}/bin/caddy hash-password --plaintext testpassword \
            > /var/lib/agent-box-web/password-hash
        )
        chmod 0600 /var/lib/agent-box-web/password-hash
      fi
    '';

    # Minimal `tls internal` Caddyfile that keeps the settings route's auth
    # gate but proxies to the settings daemon's unix socket. Same env
    # placeholder the module wires up, so agent-web-auth-secrets still feeds
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
            reverse_proxy unix//run/agent-box-settings/agent.sock
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
    machine.wait_for_unit("agent-box-agent.service")
    machine.wait_for_unit("agent-box-settings-agent.service")
    client.wait_for_unit("multi-user.target")

    def tmux(cmd):
        # Run a tmux command as the agent user against its own server (the
        # socket lives under the agent unit's RuntimeDirectory, not /tmp).
        return (
            "su -s /bin/sh agent -c 'env TMUX_TMPDIR=/run/agent-box-agent "
            "tmux -L agent-box " + cmd + "'"
        )

    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # Daemon runs AS the agent user (no root).
    machine.succeed(
        "systemctl show agent-box-settings-agent --property=User | grep -x 'User=agent'"
    )

    # Issue #49: the daemon listens ONLY on the systemd-owned unix socket —
    # 0660 agent:caddy, no TCP listener for other local users to reach.
    machine.succeed(
        "stat -c '%U %G %a' /run/agent-box-settings/agent.sock | grep -x 'agent caddy 660'"
    )
    machine.fail("ss -tln | grep -q ':7781'")

    sock_curl = "curl -s --max-time 10 --unix-socket /run/agent-box-settings/agent.sock"

    # The owning user can talk to its own daemon over the socket...
    # (grep without -q: -q exits on first match and closes the pipe while
    # curl is still writing the page -> curl exit 23.)
    machine.succeed(
        f"su -s /bin/sh agent -c '{sock_curl} http://localhost/agent/settings/' "
        "| grep 'Settings for agent' >/dev/null"
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
        "| grep 'Settings for agent' >/dev/null"
    )

    # No env file exists yet.
    machine.fail("test -e /home/agent/.config/agent-box/env")

    # POST a secret through the page (never touches the terminal/chat).
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'key=GH_TOKEN&value=ghp_supersecret' "
        "https://box.test/agent/settings/set | grep -x 303"
    )

    # File written, owned by agent, mode 0600, with the value.
    machine.succeed(
        "stat -c '%U %a' /home/agent/.config/agent-box/env | grep -x 'agent 600'"
    )
    machine.succeed("grep -q '^GH_TOKEN=ghp_supersecret$' /home/agent/.config/agent-box/env")

    # The page lists the key NAME but NEVER the value.
    page = client.succeed(f"{curl} -u agent:testpassword https://box.test/agent/settings/")
    assert "GH_TOKEN" in page, "key name should be listed"
    assert "ghp_supersecret" not in page, "value must never be rendered"

    # Delete the key.
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'key=GH_TOKEN' https://box.test/agent/settings/delete | grep -x 303"
    )
    machine.fail("grep -q GH_TOKEN /home/agent/.config/agent-box/env")

    # Issue 89: the user env file must NOT be a unit-level EnvironmentFile —
    # that's a snapshot from unit start, and sessions are respawned by the
    # long-lived supervisor, so UI-added secrets never reached restarted
    # sessions (and deleted keys never left). The spawn wrapper below is
    # the live source instead.
    machine.fail(
        "systemctl show agent-box-agent --property=EnvironmentFiles "
        "| grep -q '/home/agent/.config/agent-box/env'"
    )

    # Dump the main session's pane environment (NUL-separated /proc environ
    # as lines) — used by the issue 89 regression subtests below.
    pane_env = (
        tmux('display -p -t "=main:" "#{pane_pid}"')
        + " | xargs -I{} sh -c \"tr '\\0' '\\n' < /proc/{}/environ\""
    )

    def restart_all_and_wait_new_pane():
        old_pane = machine.succeed(tmux('display -p -t "=main:" "#{pane_pid}"')).strip()
        client.succeed(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-X POST https://box.test/agent/settings/restart | grep -x 303"
        )
        machine.wait_until_succeeds(
            tmux('display -p -t "=main:" "#{pane_pid}"')
            + f" | grep . | grep -vx '{old_pane}'",
            timeout=90,
        )

    # Issue 89 regression test: secrets saved through the page reach the
    # SESSION's process environment after a page-triggered restart (the
    # spawn wrapper re-reads the env file; the old unit-level
    # EnvironmentFile was a stale snapshot from unit start)...
    with subtest("UI-added env reaches restarted sessions"):
        machine.wait_until_succeeds(tmux("has-session -t =main"), timeout=120)
        for kv in ["key=UI_SECRET&value=from-the-ui", "key=UI_KEEP&value=stays"]:
            client.succeed(
                f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
                f"-d '{kv}' https://box.test/agent/settings/set | grep -x 303"
            )
        restart_all_and_wait_new_pane()
        # wait_until: right after spawn the pane may still be the wrapper
        # (pre-exec), whose /proc environ doesn't show the exports yet.
        machine.wait_until_succeeds(
            pane_env + " | grep -qx 'UI_SECRET=from-the-ui'", timeout=30
        )
        machine.succeed(pane_env + " | grep -qx 'UI_KEEP=stays'")

    # ...and a DELETED key is gone from the next spawn (the old unit-level
    # env kept stale values alive until reboot). UI_KEEP doubles as the
    # exec sentinel: once it shows up, the agent env is live, so the same
    # read proving UI_KEEP present must show UI_SECRET absent.
    with subtest("deleted env leaves restarted sessions"):
        client.succeed(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-d 'key=UI_SECRET' https://box.test/agent/settings/delete | grep -x 303"
        )
        restart_all_and_wait_new_pane()
        machine.wait_until_succeeds(
            pane_env + " > /tmp/pane-env && grep -qx 'UI_KEEP=stays' /tmp/pane-env",
            timeout=30,
        )
        machine.fail("grep -q '^UI_SECRET=' /tmp/pane-env")

    # Issue 54: with selfUpdate enabled the page shows the Update card...
    assert "Update box" in page, "Update box card should be rendered when selfUpdate is on"
    # ...including the running rev as a GitHub commit link (selfUpdate.rev +
    # the default repo), so the page answers "what version is this box on".
    assert (
        "github.com/defangdevs/agent-box/commit/"
        "0000000000000000000000000000000000000000" in page
    ), "Update card should link the running rev to its GitHub commit"
    assert "<code>000000000000</code>" in page, "Update card should show the short rev"

    # ...and POSTing to /update triggers agent-box-update.service through the
    # daemon's sudo -n systemctl start --no-block. The unit was inactive
    # before; activating it in this offline VM makes it fail (curl can't reach
    # GitHub), which is exactly the observable we want: the trigger worked.
    machine.fail("systemctl is-active --quiet agent-box-update.service")
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-X POST https://box.test/agent/settings/update | grep -x 303"
    )
    machine.wait_until_succeeds(
        "systemctl is-failed --quiet agent-box-update.service", timeout=60
    )

    # mallory (not an agent-box user) must not be able to trigger an update.
    machine.fail(
        "su -s /bin/sh mallory -c '/run/wrappers/bin/sudo -n "
        "/run/current-system/sw/bin/systemctl start --no-block agent-box-update.service'"
    )
  '';
}
