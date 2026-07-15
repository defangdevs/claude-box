# VM test for services.claude-box.runtimeAgents: the operator adds and
# removes agent users at runtime — no nixos-rebuild — through the
# root-owned claude-box-agent helper behind an operator-only sudo entry.
# Exercises:
#   - the sudo split: the operator can invoke the helper, other declarative
#     users and runtime agents cannot,
#   - input validation (name shape, password shape) before any state changes,
#   - the full add path: OS user, state dir, 0640 root:caddy vhost snippet
#     with the bcrypt hash inline, caddy reload, template units up
#     (claude-box@, claude-web-terminal@, claude-box-settings@),
#   - the picker daemon listing declarative + runtime agents at request time,
#   - basic auth on the runtime agent's terminal and settings page,
#     NOTE: ttyd 1.7.7 is broken on the flake-locked nixos-unstable
#     (libwebsockets 4.4.5 lost the evlib_uv plugin, ttyd dies at startup;
#     deployed AWS boxes run 25.11 stable and are unaffected), so like
#     web-fail2ban this test never asserts on a LIVE ttyd — the terminal
#     leg checks auth (caddy-side) and unit wiring; the settings leg is
#     exercised end-to-end (its daemon works fine),
#   - the operator settings page's Add-agent card (daemon -> sudo -> helper),
#   - boot reconcile: stopped instances are brought back by
#     claude-box-runtime-reconcile (what runs after a reboot/spot restart),
#   - remove: units stopped, vhost + state gone, user deleted, home
#     preserved — and the name can be re-added.
#
# Like the other tests, lib.mkForce-swaps the module Caddyfile for a minimal
# `tls internal` one (no ACME in the sandbox) that keeps the same shape:
# operator settings route, the vhostsDir glob import, and the picker proxy.
{ claude-box }:
{
  name = "claude-box-runtime-agents";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ claude-box ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl ];
    services.claude-box = {
      enable = true;
      agent = "claude";
      users.agent = {
        web.passwordHashFile = "/var/lib/claude-box-web/password-hash";
      };
      # A declarative NON-operator agent: gets the broad allowlist (caddy
      # reload) but must NOT be able to invoke claude-box-agent.
      users.worker = { };
      web = {
        enable = true;
        domain = "box.test";
        user = "agent";
        fail2ban = false;
      };
      runtimeAgents.enable = true;
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

    # Minimal `tls internal` Caddyfile mirroring the module's runtime-agents
    # rendering: operator settings route, runtime vhost glob import, picker
    # daemon as the catch-all.
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
        import /var/lib/claude-box-vhosts/*.caddy
        handle {
          reverse_proxy unix//run/claude-box-picker.sock
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
    machine.wait_for_unit("claude-box-picker.socket")
    machine.wait_for_unit("claude-box-settings-agent.service")
    client.wait_for_unit("multi-user.target")

    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --max-time 30 --resolve box.test:443:{machine_ip}"
    sudo_helper = "/run/wrappers/bin/sudo -n /run/current-system/sw/bin/claude-box-agent"

    # --- sudo split -------------------------------------------------------
    # The operator can run the helper; a declarative non-operator cannot.
    machine.succeed(f"su -s /bin/sh agent -c '{sudo_helper} list'")
    machine.fail(f"su -s /bin/sh worker -c '{sudo_helper} list'")

    # --- validation happens before any state changes ----------------------
    machine.fail(f"su -s /bin/sh agent -c 'echo runtimepassword1 | {sudo_helper} add Bad.Name'")
    machine.fail(f"su -s /bin/sh agent -c 'echo short | {sudo_helper} add scratch'")
    machine.fail("id -u scratch")
    # Reserved / declarative names are refused.
    machine.fail(f"su -s /bin/sh agent -c 'echo runtimepassword1 | {sudo_helper} add root'")
    machine.fail(f"su -s /bin/sh agent -c 'echo runtimepassword1 | {sudo_helper} add worker'")

    # --- picker lists only declarative users so far ------------------------
    page = client.succeed(f"{curl} https://box.test/")
    assert "agent" in page and "scratch" not in page

    # --- add ---------------------------------------------------------------
    machine.succeed(f"su -s /bin/sh agent -c 'echo runtimepassword1 | {sudo_helper} add scratch'")
    machine.succeed("id -u scratch")
    machine.succeed("test -d /var/lib/claude-box-agents/scratch")
    machine.succeed(
        "stat -c '%U %G %a' /var/lib/claude-box-vhosts/scratch.caddy | grep -x 'root caddy 640'"
    )
    # The bcrypt hash lives only in the root:caddy snippet — never readable
    # by other users (the store-rendered Caddyfile holds no hashes either).
    machine.fail("su -s /bin/sh worker -c 'cat /var/lib/claude-box-vhosts/scratch.caddy'")

    machine.wait_for_unit("claude-box@scratch.service")
    # ttyd itself is broken on this nixpkgs pin (header note), so assert the
    # terminal unit's WIRING instead of a live socket: it runs as scratch and
    # binds tty.sock inside its own per-instance RuntimeDirectory (the
    # anti-squatting layout).
    machine.succeed(
        "systemctl show claude-web-terminal@scratch -p User | grep -x 'User=scratch'"
    )
    machine.succeed(
        "systemctl show claude-web-terminal@scratch -p RuntimeDirectory "
        "| grep -x 'RuntimeDirectory=claude-web-terminal/scratch'"
    )
    machine.succeed(
        "systemctl show claude-web-terminal@scratch -p ExecStart "
        "| grep -q -- '-i /run/claude-web-terminal/scratch/tty.sock'"
    )
    machine.succeed(
        "systemctl show claude-web-terminal@scratch -p ExecStart "
        "| grep -q -- '-U scratch:caddy'"
    )
    # Memory-pressure stance carries over from the declarative units.
    machine.succeed(
        "systemctl show claude-box@scratch --property=OOMScoreAdjust | grep -x 'OOMScoreAdjust=500'"
    )
    # Runtime agents get NO sudo at all.
    machine.fail(f"su -s /bin/sh scratch -c '{sudo_helper} list'")
    machine.fail(
        "su -s /bin/sh scratch -c '/run/wrappers/bin/sudo -n "
        "/run/current-system/sw/bin/systemctl reload caddy.service'"
    )

    # --- reachable through caddy, behind its own basic auth ----------------
    picker = client.succeed(f"{curl} https://box.test/")
    assert "scratch" in picker, "picker should list the runtime agent"
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' https://box.test/scratch/ | grep -x 401"
    )
    # The right password gets past caddy's basic_auth (the inline bcrypt hash
    # verifies) — upstream is the broken ttyd, so anything but 401 proves the
    # auth leg. The settings check below covers the same vhost end-to-end.
    code = client.succeed(
        f"{curl} -u scratch:runtimepassword1 -o /dev/null -w '%{{http_code}}' "
        "https://box.test/scratch/"
    ).strip()
    assert code != "401", f"correct password should pass basic auth, got {code}"
    # The operator's password does not open the runtime agent's terminal.
    client.succeed(
        f"{curl} -u scratch:testpassword -o /dev/null -w '%{{http_code}}' "
        "https://box.test/scratch/ | grep -x 401"
    )
    client.succeed(
        f"{curl} -u scratch:runtimepassword1 https://box.test/scratch/settings/ "
        "| grep 'Settings for scratch' >/dev/null"
    )

    # --- operator settings page: Add-agent card ----------------------------
    page = client.succeed(f"{curl} -u agent:testpassword https://box.test/agent/settings/")
    assert "Additional agents" in page, "operator page should render the Add-agent card"
    assert "scratch" in page, "existing runtime agent should be listed"
    # A runtime agent's own settings page must NOT grow the card (no sudo).
    page = client.succeed(f"{curl} -u scratch:runtimepassword1 https://box.test/scratch/settings/")
    assert "Additional agents" not in page

    client.succeed(
        f"{curl} -u agent:testpassword -o /dev/null -w '%{{http_code}}' "
        "-d 'name=webby&password=runtimepassword2' "
        "https://box.test/agent/settings/add-agent | grep -x 303"
    )
    machine.wait_until_succeeds("id -u webby", timeout=60)
    machine.wait_for_unit("claude-box@webby.service")

    # --- boot reconcile -----------------------------------------------------
    # Simulate the post-reboot state (instances down, state dir intact) and
    # prove the oneshot brings every recorded agent back.
    machine.succeed(
        "systemctl stop claude-web-terminal@scratch.service claude-box@scratch.service "
        "claude-box-settings@scratch.socket claude-web-terminal@webby.service "
        "claude-box@webby.service claude-box-settings@webby.socket"
    )
    machine.succeed("systemctl restart claude-box-runtime-reconcile.service")
    machine.wait_for_unit("claude-box@scratch.service")
    machine.wait_for_unit("claude-box@webby.service")
    machine.wait_until_succeeds(
        "systemctl is-active --quiet claude-box-settings@scratch.socket", timeout=60
    )

    # --- remove -------------------------------------------------------------
    machine.succeed(f"su -s /bin/sh agent -c '{sudo_helper} remove webby'")
    machine.fail("id -u webby")
    machine.fail("test -e /var/lib/claude-box-vhosts/webby.caddy")
    machine.fail("test -d /var/lib/claude-box-agents/webby")
    machine.succeed("test -d /home/webby")  # home preserved by design
    machine.fail("systemctl is-active --quiet claude-box@webby.service")
    picker = client.succeed(f"{curl} https://box.test/")
    assert "webby" not in picker

    # A removed name can be re-added (preserved home gets re-owned).
    machine.succeed("touch /home/webby/leftover && chown 0:0 /home/webby/leftover")
    machine.succeed(f"su -s /bin/sh agent -c 'echo runtimepassword3 | {sudo_helper} add webby'")
    machine.succeed("stat -c '%U' /home/webby/leftover | grep -x webby")
    machine.wait_for_unit("claude-box@webby.service")
  '';
}
