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
        # Root catch-all: the session manager and its /sessions/* CRUD
        # routes (the daemon runs in AGENT_BOX_HOME mode for web.user) —
        # same auth gate, same upstream, mirroring the module Caddyfile.
        handle {
          route {
            basic_auth bcrypt agent {
              agent {$WEB_PASSWORD_HASH_AGENT}
            }
            reverse_proxy unix//run/agent-box-settings/agent.sock
          }
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

    # Dump the environment of the main session's AGENT process. The pane
    # pid is the `sh -c "wrapper cmd || exec bash"` shell; the env-exec
    # wrapper (and the agent it execs, same pid) is that shell's CHILD —
    # /proc environ is an exec-time snapshot, so the exports only show up
    # there. Empty output (no child yet) just fails the grep and retries.
    agent_env = (
        tmux('display -p -t "=main:" "#{pane_pid}"')
        + " | xargs -I{} sh -c 'pgrep -P {} | head -1'"
        + " | xargs -I{} sh -c \"tr '\\0' '\\n' < /proc/{}/environ\""
    )

    def wait_new_pane(restart_cmd):
        old_pane = machine.succeed(tmux('display -p -t "=main:" "#{pane_pid}"')).strip()
        client.succeed(restart_cmd)
        machine.wait_until_succeeds(
            tmux('display -p -t "=main:" "#{pane_pid}"')
            + f" | grep . | grep -vx '{old_pane}'",
            timeout=90,
        )

    # Issue 89 regression test: secrets saved through the page reach the
    # SESSION's process environment after a PER-SESSION restart (the spawn
    # wrapper re-reads the env file; the old unit-level EnvironmentFile
    # was a stale snapshot from unit start)...
    with subtest("UI-added env reaches a restarted session (spawn wrapper)"):
        machine.wait_until_succeeds(tmux("has-session -t =main"), timeout=120)
        for kv in ["key=UI_SECRET&value=from-the-ui", "key=UI_KEEP&value=stays"]:
            client.succeed(
                f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
                f"-d '{kv}' https://box.test/agent/settings/set | grep -x 303"
            )
        wait_new_pane(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-d 'name=main' https://box.test/sessions/restart | grep -x 303"
        )
        machine.wait_until_succeeds(
            agent_env + " | grep -qx 'UI_SECRET=from-the-ui'", timeout=30
        )
        machine.succeed(agent_env + " | grep -qx 'UI_KEEP=stays'")

    # ...and "Restart all" bounces the WHOLE unit (the daemon SIGTERMs the
    # supervisor — no sudo), so unit-level EnvironmentFiles like tokenDir
    # are re-read, and a DELETED key is gone from the next spawn. UI_KEEP
    # doubles as the exec sentinel: the same read that proves it arrived
    # must show UI_SECRET absent.
    with subtest("restart-all bounces the unit; deleted env leaves"):
        client.succeed(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-d 'key=UI_SECRET' https://box.test/agent/settings/delete | grep -x 303"
        )
        old_main = machine.succeed(
            "systemctl show agent-box-agent --property=MainPID --value"
        ).strip()
        wait_new_pane(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-X POST https://box.test/agent/settings/restart | grep -x 303"
        )
        machine.wait_until_succeeds(
            "p=$(systemctl show agent-box-agent --property=MainPID --value); "
            f"[ -n \"$p\" ] && [ \"$p\" != 0 ] && [ \"$p\" != {old_main} ]",
            timeout=60,
        )
        machine.wait_until_succeeds(
            agent_env + " > /tmp/agent-env && grep -qx 'UI_KEEP=stays' /tmp/agent-env",
            timeout=30,
        )
        machine.fail("grep -q '^UI_SECRET=' /tmp/agent-env")

    # Issue 54: with selfUpdate enabled the page shows the Update card...
    assert "Update box" in page, "Update box card should be rendered when selfUpdate is on"
    # ...including the running rev as a GitHub commit link (selfUpdate.rev +
    # the default repo), so the page answers "what version is this box on".
    assert (
        "github.com/defangdevs/agent-box/commit/"
        "0000000000000000000000000000000000000000" in page
    ), "Update card should link the running rev to its GitHub commit"
    assert "<code>000000000000</code>" in page, "Update card should show the short rev"
    # Without JavaScript the card still links to GitHub's comparison. In a
    # browser the progressive update check replaces this fallback with either
    # a current or an "update available" status linking the same changes.
    assert 'id="update-status"' in page, "Update card should include its status target"
    assert (
        "github.com/defangdevs/agent-box/compare/"
        "0000000000000000000000000000000000000000...HEAD" in page
    ), "Update status should fall back to a GitHub changes link"
    assert "Check GitHub for changes" in page, "Update status should have a no-JS fallback"

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
