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
#   - the root tabbed terminal workspace (the settings daemon in
#     AGENT_BOX_HOME mode for the primary web user; issue 119) — one tab per
#     session, panes iframing the per-session ttyd URLs, server-side ?tab=
#     selection — and its /sessions/* CRUD routes, all behind auth — nothing
#     on the vhost is served unauthenticated anymore (the old picker and its
#     public sessions.json are gone),
#   - session CRUD on the settings page (back=settings redirects there),
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
      # Leave the host label unset so auto-derived Remote Control names fall
      # back to the public web.domain rather than the internal kernel
      # hostname (issue: derived names showed the internal EC2 fqdn).
      remoteControlHost = "";
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

    # With remoteControlHost unset, the auto-derived "<user>-<session>@<host>"
    # Remote Control name takes its host suffix from the public web.domain,
    # NOT the internal kernel hostname — and every session (including "main")
    # gets the "-<session>" suffix (no "main" special case). The supervisor
    # bakes both into its start script, so assert those literals.
    start_script = machine.succeed(
        "systemctl show agent-box-agent --property=ExecStart --value "
        "| grep -o '/nix/store/[^ ;]*-agent-box-agent-start'"
    ).strip()
    script_body = machine.succeed(f"cat {start_script}")
    assert "host=box.test" in script_body, script_body
    assert "rcname=agent-$sname" in script_body, script_body

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

    # --- auto-named add: no NAME → derived from the agent -----------------
    # First codex-derived name is the bare agent name (no session is literally
    # "codex" yet — "helper" runs codex but under its own name).
    machine.succeed("su -s /bin/sh agent -c 'agent-box-session add --agent codex'")
    machine.wait_until_succeeds(tmux("has-session -t =codex"), timeout=60)
    machine.succeed(
        "jq -e '.sessions.codex.agent == \"codex\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )
    # A second codex-derived name collides with "codex", so it gets a short
    # random suffix ("codex-XXXX") — a distinct, valid session name.
    machine.succeed("su -s /bin/sh agent -c 'agent-box-session add --agent codex'")
    machine.succeed(
        "jq -e '[.sessions | keys[] | select(test(\"^codex-[0-9a-f]+$\"))] | length == 1' "
        "/home/agent/.config/agent-box/sessions.json"
    )
    suffixed = machine.succeed(
        "jq -r '.sessions | keys[] | select(test(\"^codex-[0-9a-f]+$\"))' "
        "/home/agent/.config/agent-box/sessions.json"
    ).strip()
    machine.wait_until_succeeds(tmux(f'has-session -t "={suffixed}"'), timeout=60)
    machine.succeed("su -s /bin/sh agent -c 'agent-box-session rm codex'")
    machine.succeed(f"su -s /bin/sh agent -c 'agent-box-session rm {suffixed}'")

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

    # --- kickoff prompt: fires once, then resumes -------------------------
    sfile = "/home/agent/.config/agent-box/sessions.json"
    with subtest("kickoff prompt is delivered once and consumed"):
        machine.succeed(
            "su -s /bin/sh agent -c "
            + shlex.quote("agent-box-session add task1 --agent codex --prompt 'do the thing'")
        )
        # Stored as initialPrompt with an id minted up front; not yet run.
        machine.succeed(
            f"jq -e '.sessions.task1.initialPrompt == \"do the thing\"' {sfile}"
        )
        machine.succeed(
            f"jq -e '.sessions.task1.hasRun == false and (.sessions.task1.boxSessionId | type == \"string\")' {sfile}"
        )
        # Once the supervisor spawns it, the prompt is consumed and hasRun set,
        # so a later respawn resumes instead of re-running the task.
        machine.wait_until_succeeds(tmux("has-session -t =task1"), timeout=60)
        machine.wait_until_succeeds(
            f"jq -e '.sessions.task1.hasRun == true and .sessions.task1.initialPrompt == null' {sfile}",
            timeout=60,
        )
        # A respawn must NOT re-prime the kickoff prompt.
        machine.succeed(tmux("kill-session -t =task1"))
        machine.succeed("sleep 6")
        machine.succeed(
            f"jq -e '.sessions.task1.initialPrompt == null and .sessions.task1.hasRun == true' {sfile}"
        )
        machine.succeed("su -s /bin/sh agent -c 'agent-box-session rm task1'")

    # --- env CLI writes the same file the settings page + wrapper use -----
    with subtest("env set/ls/rm on ~/.config/agent-box/env"):
        machine.succeed("su -s /bin/sh agent -c 'agent-box-session env set MY_TOKEN sekret'")
        machine.succeed("grep -qx 'MY_TOKEN=sekret' /home/agent/.config/agent-box/env")
        machine.succeed("stat -c '%a' /home/agent/.config/agent-box/env | grep -x 600")
        env_ls = machine.succeed("su -s /bin/sh agent -c 'agent-box-session env ls'")
        # ls surfaces the KEY but never the value (mirrors the settings page).
        assert "MY_TOKEN" in env_ls and "sekret" not in env_ls, env_ls
        machine.succeed("su -s /bin/sh agent -c 'agent-box-session env rm MY_TOKEN'")
        machine.fail("grep -q MY_TOKEN /home/agent/.config/agent-box/env")

    # --- restart --all bounces every listed session -----------------------
    with subtest("restart --all"):
        old_all = machine.succeed(tmux('display -p -t "=main:" "#{pane_pid}"')).strip()
        machine.succeed("su -s /bin/sh agent -c 'agent-box-session restart --all'")
        machine.wait_until_succeeds(
            tmux('display -p -t "=main:" "#{pane_pid}"') + f" | grep . | grep -vx '{old_all}'",
            timeout=60,
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

    # The root page (behind auth) is the tabbed terminal workspace (issue
    # 119): a tab per session, the selected (live) session's pane iframing
    # its ttyd deep link. Never a session's argv/cwd/env (may hold secrets).
    root_page = client.succeed(f"{curl} -u agent:testpassword https://box.test/")
    assert 'id="tab-bar"' in root_page, root_page
    assert 'data-tab="main" href="/?tab=main" aria-current="page"' in root_page, root_page
    assert 'src="/agent/?arg=main"' in root_page, root_page
    assert "workingDirectory" not in root_page, root_page

    # The root page's CRUD routes (behind auth) can add a session; the
    # workspace redirect lands on the new session's tab. The name is always
    # auto-derived from the agent (there is no name field in the form): with
    # no session literally named "claude" yet, the first claude add lands on
    # the bare-agent-name tab. Assert the raw Location header (h2 lowercases
    # it, CRLF line ends — no grep -x): what the daemon EMITS is the contract,
    # curl's %{redirect_url} resolution is not. Any submitted "name" field is
    # ignored, so passing a bogus one changes nothing.
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -D - "
        "-d 'name=ignored&agent=claude' "
        "https://box.test/sessions/add "
        "| grep -i '^location: /?ok=session_added&tab=claude'"
    )
    machine.wait_until_succeeds(tmux("has-session -t =claude"), timeout=60)
    machine.succeed(
        "jq -e '.sessions.claude.agent == \"claude\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )

    # ?tab= selects a tab server-side (the no-JS switching path): the new
    # tab is current and its live pane iframes its ttyd URL.
    tab_page = client.succeed(f"{curl} -u agent:testpassword 'https://box.test/?tab=claude'")
    assert 'data-tab="claude" href="/?tab=claude" aria-current="page"' in tab_page, tab_page
    assert 'src="/agent/?arg=claude"' in tab_page, tab_page
    # main is still a tab, just not the current one.
    assert 'data-tab="main" href="/?tab=main">' in tab_page, tab_page

    # Delete it (delist + kill) so "claude" is free again for later subtests.
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=claude' "
        "https://box.test/sessions/delete | grep -x 303"
    )
    machine.succeed("sleep 6")
    machine.fail(tmux("has-session -t =claude"))

    # The add-session form carries an optional kickoff prompt through to
    # initialPrompt (first-spawn only, cleared on resume like the CLI). The
    # name is auto-derived and "claude" is free again, so assert on that key.
    # Read initialPrompt right after the write, before the supervisor's next
    # ~2s tick spawns the session and consumes the prompt.
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'agent=claude' --data-urlencode 'prompt=hello there' "
        "https://box.test/sessions/add | grep -x 303"
    )
    machine.succeed(
        "jq -e '.sessions.claude.initialPrompt == \"hello there\"' "
        "/home/agent/.config/agent-box/sessions.json"
    )
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=claude' https://box.test/sessions/delete | grep -x 303"
    )
    machine.succeed("sleep 6")
    machine.fail(tmux("has-session -t =claude"))

    # Session CRUD is rejected without credentials.
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' "
        "-d 'agent=claude' "
        "https://box.test/sessions/add | grep -x 401"
    )

    # The session CRUD routes stay at the root for the primary user (the
    # old settings-path routes remain gone)...
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'agent=claude' "
        "https://box.test/agent/settings/sessions/add | grep -x 404"
    )
    # ...but the settings page renders the session manager again (the root
    # page is the workspace now, issue 119), with back=settings so its forms
    # redirect back to the settings page rather than to the workspace.
    settings_page = client.succeed(
        f"{curl} -u agent:testpassword https://box.test/agent/settings/"
    )
    assert "Add session" in settings_page, settings_page
    assert 'name="back" value="settings"' in settings_page, settings_page
    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -D - "
        "-d 'name=main&back=settings' "
        "https://box.test/sessions/restart "
        "| grep -i '^location: /agent/settings/?ok=session_restarted'"
    )
    # (that restart killed main; the supervisor brings it back)
    machine.wait_until_succeeds(tmux("has-session -t =main"), timeout=60)

    # ttyd serves per-session deep links: the unit runs with --url-arg.
    machine.succeed("systemctl cat agent-web-terminal-agent | grep -q -- --url-arg")
    machine.succeed(
        "grep -q -- '-T hyperlinks' "
        "$(systemctl show agent-web-terminal-agent --property=ExecStart --value "
        "| grep -o '/nix/store/[^ ]*agent-box-agent-attach')"
    )

    # Working-directory picker (issue 131): the add-session form browses the
    # user's home one directory level at a time via a read-only JSON endpoint,
    # and a session can be anchored in a chosen directory.
    with subtest("session working-directory picker + add-with-cwd"):
        machine.succeed("su -s /bin/sh agent -c 'mkdir -p /home/agent/work/repo'")

        # "~" lists home's immediate children (including the fresh work/), a
        # deeper path lists that directory's children, and both report ok.
        dirs = client.succeed(
            f"{curl} -u agent:testpassword 'https://box.test/sessions/dirs?path=~'"
        )
        assert '"ok": true' in dirs, dirs
        assert '"work"' in dirs, dirs
        sub = client.succeed(
            f"{curl} -u agent:testpassword 'https://box.test/sessions/dirs?path=~/work'"
        )
        assert '"repo"' in sub, sub

        # The listing is confined to $HOME: a ../ climb-out and an absolute
        # path outside home are both refused (ok:false, no entries leaked).
        for bad in ["~/../../etc", "/etc"]:
            escaped = client.succeed(
                f"{curl} -u agent:testpassword 'https://box.test/sessions/dirs?path={bad}'"
            )
            assert '"ok": false' in escaped, escaped
            assert '"dirs": []' in escaped, escaped

        # A non-existent directory, or one outside $HOME, is a 400 (tmux -c
        # would fail on a missing cwd) and no session is created. "claude"
        # was deleted above, so a rejected add must leave it absent.
        for bad in ["~/nope", "/etc"]:
            client.succeed(
                f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
                f"-d 'agent=claude&cwd={bad}' "
                "https://box.test/sessions/add | grep -x 400"
            )
        machine.succeed(
            "jq -e '(.sessions.claude // null) == null' "
            "/home/agent/.config/agent-box/sessions.json"
        )

        # Add a session anchored in ~/work/repo: the name auto-derives to the
        # bare "claude" (free again), it is stored as an absolute path, and the
        # supervisor starts the agent in that directory.
        client.succeed(
            f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
            "-d 'agent=claude&cwd=~/work/repo' "
            "https://box.test/sessions/add | grep -x 303"
        )
        machine.succeed(
            "jq -e '.sessions.claude.workingDirectory == \"/home/agent/work/repo\"' "
            "/home/agent/.config/agent-box/sessions.json"
        )
        machine.wait_until_succeeds(tmux("has-session -t =claude"), timeout=60)
        machine.wait_until_succeeds(
            tmux('display -p -t "=claude:" "#{pane_current_path}"')
            + " | grep -x /home/agent/work/repo",
            timeout=60,
        )

        # Clean up so the migration subtest starts from a known session set.
        client.succeed(
            f"{curl} -u agent:testpassword -o /dev/null "
            "-d 'name=claude' https://box.test/sessions/delete"
        )
        machine.succeed("sleep 6")
        machine.fail(tmux("has-session -t =claude"))

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
