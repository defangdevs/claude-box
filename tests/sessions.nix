# VM test for issue #59: sessions are runtime data, decoupled from linux
# users. One hardened unit per USER supervises tmux sessions declared in the
# user-owned ~/.config/agent-box/sessions.json. Exercises:
#   - first-boot seeding of the Nix-declared config into sessions.json
#     (legacy per-user options standing in for a session named "main"),
#   - runtime session add/rm via the agent-box-session CLI — as the user,
#     no sudo, no nixos-rebuild,
#   - runtime-created sessions still living inside the hardened agent unit's
#     cgroup (the tmux server is a child of the supervisor),
#   - the supervisor recreating a killed listed session (restart semantics)
#     and NOT recreating a delisted one (destroy semantics),
#   - both agent CLIs installed regardless of what sessions run
#     (installAgents default),
#   - browser tmux clients advertise OSC 8 support, preserving a long hidden
#     hyperlink target when its visible URL wraps across terminal rows (#18),
#   - the root session manager page (the settings daemon in AGENT_BOX_HOME
#     mode for the primary web user) and its /sessions/* CRUD routes, all
#     behind auth — nothing on the vhost is served unauthenticated anymore
#     (the old picker and its public sessions.json are gone),
#   - ttyd running with --url-arg so /<user>/?arg=<session> deep links work.
#
# Like the other tests, lib.mkForce-swaps the module Caddyfile for a minimal
# `tls internal` one (no ACME in the sandbox) that keeps the same routing
# shape: /agent/settings* and the root catch-all both inside the auth gate,
# proxied to the settings daemon's unix socket.
{ agent-box }:
{
  name = "agent-box-sessions";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ agent-box ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
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
    import base64
    import re
    import shlex

    start_all()
    machine.wait_for_unit("agent-box-agent.service")
    machine.wait_for_unit("agent-box-settings-agent.service")
    machine.wait_for_unit("caddy.service")
    client.wait_for_unit("multi-user.target")

    def as_agent(cmd):
        return "su -s /bin/sh agent -c " + shlex.quote(cmd)

    def tmux(cmd):
        # Run a tmux command as the agent user against its own server (the
        # socket lives under the agent unit's RuntimeDirectory, not /tmp).
        return as_agent(
            "env TMUX_TMPDIR=/run/agent-box-agent "
            "tmux -L agent-box " + cmd
        )

    # --- first boot: legacy options seeded a "main" session --------------
    machine.wait_until_succeeds(tmux("has-session -t =main"), timeout=120)
    machine.succeed(
        "stat -c '%U %a' /home/agent/.config/agent-box/sessions.json "
        "| grep -x 'agent 600'"
    )
    machine.succeed(
        "jq -e '.sessions.main.agent == \"claude\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # Both agent CLIs are installed even though no session uses codex yet
    # (installAgents defaults to all supported agents).
    machine.succeed("test -x /run/current-system/sw/bin/claude")
    machine.succeed("test -x /run/current-system/sw/bin/codex")
    machine.succeed("su -s /bin/sh agent -c 'test -x /home/agent/.codex/packages/standalone/current/codex'")
    machine.succeed("test -x /run/current-system/sw/bin/bwrap")

    # HTTPS github clones authenticate via GH_TOKEN: gh's credential helper
    # is wired system-wide, and gh itself is on the agent unit's PATH.
    machine.succeed(
        "su -s /bin/sh agent -c "
        "'git config --get credential.https://github.com.helper' | grep -q 'gh auth git-credential'"
    )
    machine.succeed("systemctl cat agent-box-agent | grep -q -- '-gh-'")

    # Claude emits its long OAuth URL inside one complete OSC 8 sequence.
    # tmux stores that metadata, but redraws plain text unless the attaching
    # xterm-256color client explicitly advertises hyperlink support. Emit a
    # 450-byte wrapped link before attach, like opening ttyd after Claude has
    # printed it, and assert tmux sends the full hidden target to the client.
    link_prefix = "https://httpbin.invalid/anything?state="
    link_suffix = "&sentinel=END_OF_FULL_URL"
    link_url = link_prefix + "a" * (450 - len(link_prefix) - len(link_suffix)) + link_suffix
    link_sequence = (
        "\x1b]8;;" + link_url + "\x1b\\"
        + link_url
        + "\x1b]8;;\x1b\\"
    )
    tmux_browser_command = "printf %s " + shlex.quote(link_sequence) + "; sleep 5"
    machine.succeed(
        tmux(
            "new-session -d -s browser-link-test "
            + shlex.quote(tmux_browser_command)
        )
    )
    tmux_attach_command = (
        "env TMUX_TMPDIR=/run/agent-box-agent "
        "tmux -T hyperlinks -L agent-box attach -t =browser-link-test"
    )
    machine.succeed(
        as_agent(
            f"TERM=xterm-256color script -q -c {shlex.quote(tmux_attach_command)} /dev/null "
            "> /tmp/tmux-browser-link"
        )
    )
    tmux_browser_output = base64.b64decode(
        machine.succeed("base64 -w0 /tmp/tmux-browser-link").strip()
    )
    hyperlink_targets = re.findall(
        rb"\x1b]8;[^;]*;([^\x1b]*)\x1b\\", tmux_browser_output
    )
    assert link_url.encode() in hyperlink_targets, tmux_browser_output
    assert b"END_OF_FULL_URL" in tmux_browser_output, tmux_browser_output

    # --- runtime add: no sudo, no rebuild ---------------------------------
    machine.succeed(
        "su -s /bin/sh agent -c 'agent-box-session add helper --agent codex'"
    )
    machine.wait_until_succeeds(tmux("has-session -t =helper"), timeout=60)
    machine.succeed(
        "jq -e '.sessions.helper.agent == \"codex\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # Re-adding an existing name errors out and must not clobber the stored
    # config (issue 100): helper keeps its codex agent.
    machine.fail(
        "su -s /bin/sh agent -c 'agent-box-session add helper --agent claude'"
    )
    machine.succeed(
        "jq -e '.sessions.helper.agent == \"codex\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # The runtime-created session runs INSIDE the hardened agent unit's
    # cgroup: the tmux server is a child of the supervisor, so systemd
    # sandboxing covers sessions added long after boot.
    # NOTE the "=helper:" (trailing colon): display/capture take a target-
    # PANE, and a bare "=name" only resolves when that session is tmux's
    # idea of the current one — otherwise it silently expands to "" (rc 0).
    server_pid = machine.succeed(tmux('display -p -t "=helper:" "#{pid}"')).strip()
    machine.succeed(f"grep -q agent-box-agent.service /proc/{server_pid}/cgroup")

    # ls shows both sessions with their agents.
    listing = machine.succeed("su -s /bin/sh agent -c 'agent-box-session ls'")
    assert "main" in listing and "helper" in listing, listing
    assert "codex" in listing, listing

    # --- shell pseudo-agent (issue 113): supervised plain login shell ------
    machine.succeed(
        "su -s /bin/sh agent -c 'agent-box-session add scratch --agent shell'"
    )
    machine.wait_until_succeeds(tmux("has-session -t =scratch"), timeout=60)
    machine.succeed(
        "jq -e '.sessions.scratch.agent == \"shell\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )
    # The pane runs the user's login shell (bash on this box), not an agent.
    machine.wait_until_succeeds(
        tmux('display -p -t "=scratch:" "#{pane_current_command}"')
        + " | grep -x bash",
        timeout=60,
    )
    # A clean `exit` must NOT land in the post-mortem bash (that fallback is
    # for agents only — for a shell it would be a confusing nested shell):
    # the session dies and the reconcile loop respawns a fresh login shell.
    old_shell_pane = machine.succeed(
        tmux('display -p -t "=scratch:" "#{pane_pid}"')
    ).strip()
    machine.succeed(tmux('send-keys -t "=scratch:" exit Enter'))
    machine.wait_until_succeeds(
        tmux('display -p -t "=scratch:" "#{pane_pid}"')
        + f" | grep . | grep -vx '{old_shell_pane}'",
        timeout=60,
    )
    machine.succeed("su -s /bin/sh agent -c 'agent-box-session rm scratch'")

    # --- restart semantics: killed listed sessions come back --------------
    # Compare pane PIDs, not session ids: killing the LAST session also ends
    # the tmux server, and a fresh server restarts session-id numbering, so
    # ids can repeat. A recreated session always has a new pane process.
    old_pane = machine.succeed(tmux('display -p -t "=main:" "#{pane_pid}"')).strip()
    assert old_pane, "pane_pid of main must not be empty"
    machine.succeed(tmux("kill-session -t =main"))
    machine.wait_until_succeeds(
        tmux('display -p -t "=main:" "#{pane_pid}"') + f" | grep . | grep -vx '{old_pane}'",
        timeout=60,
    )

    # --- destroy semantics: delisted sessions stay gone -------------------
    machine.succeed("su -s /bin/sh agent -c 'agent-box-session rm helper'")
    machine.fail(tmux("has-session -t =helper"))
    machine.succeed("sleep 6")  # a few supervisor ticks
    machine.fail(tmux("has-session -t =helper"))
    machine.succeed(
        "jq -e '.sessions | has(\"helper\") | not' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # --- web surface -------------------------------------------------------
    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # NOTHING on the vhost is public anymore: the root session manager
    # challenges for auth, and the old public sessions.json is gone (its
    # path now falls into the auth-gated catch-all).
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' https://box.test/ | grep -x 401"
    )
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' "
        "https://box.test/agent/sessions.json | grep -x 401"
    )

    # The root page (behind auth) lists the sessions with terminal deep
    # links, never a session's argv/cwd/env (those may hold secrets).
    root_page = client.succeed(f"{curl} -u agent:testpassword https://box.test/")
    assert "main" in root_page, root_page
    assert "/agent/?arg=main" in root_page, root_page
    assert "workingDirectory" not in root_page, root_page

    # The root page's CRUD routes (behind auth) can add a session...
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web&agent=claude' "
        "https://box.test/sessions/add | grep -x 303"
    )
    machine.wait_until_succeeds(tmux("has-session -t =web"), timeout=60)

    # A duplicate add via the web is a 409 and the stored config survives
    # (a silent overwrite would reset it to defaults — issue 100).
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web&agent=codex' "
        "https://box.test/sessions/add | grep -x 409"
    )
    machine.succeed(
        "jq -e '.sessions.web.agent == \"claude\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # ...and delete it again (delist + kill).
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web' "
        "https://box.test/sessions/delete | grep -x 303"
    )
    machine.succeed("sleep 6")
    machine.fail(tmux("has-session -t =web"))

    # Session CRUD is rejected without credentials.
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' "
        "-d 'name=pwn&agent=claude' "
        "https://box.test/sessions/add | grep -x 401"
    )

    # The sessions moved OFF the settings page (they live at / now): the
    # old settings-page CRUD routes are gone for the primary user...
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=web2&agent=claude' "
        "https://box.test/agent/settings/sessions/add | grep -x 404"
    )
    # ...and the page itself no longer renders the session manager.
    settings_page = client.succeed(
        f"{curl} -u agent:testpassword https://box.test/agent/settings/"
    )
    assert "Add session" not in settings_page, settings_page

    # ttyd serves per-session deep links: the unit runs with --url-arg.
    machine.succeed("systemctl cat agent-web-terminal-agent | grep -q -- --url-arg")
    machine.succeed(
        "grep -q -- '-T hyperlinks' "
        "$(systemctl show agent-web-terminal-agent --property=ExecStart --value "
        "| grep -o '/nix/store/[^ ]*agent-box-agent-attach')"
    )

    # Rename migration (issue 70): re-running activation moves old-name
    # (claude-box) state to the agent-box paths exactly once, and never
    # clobbers live new-name state.
    with subtest("claude-box -> agent-box rename migration"):
        # Move path: old token dir, new-name dir still empty (tmpfiles shape).
        machine.succeed("mkdir -p /etc/claude-box && echo 'MIG=1' > /etc/claude-box/mig.env")
        # No-clobber path: new-name web state (cookie secret) already live.
        machine.succeed("mkdir -p /var/lib/claude-box-web && touch /var/lib/claude-box-web/stale-marker")
        machine.succeed("/run/current-system/activate")
        machine.succeed("test -f /etc/agent-box/mig.env")
        machine.succeed("test ! -e /etc/claude-box")
        machine.succeed("test -s /var/lib/agent-box-web/cookie-secret-agent")
        machine.succeed("test -f /var/lib/claude-box-web/stale-marker")
  '';
}
