# VM test for issue #40: an agent user can add a new virtual host by writing
# a snippet into ~/sites/ and running `sudo systemctl reload caddy.service`,
# without any nixos-rebuild. Exercises the tmpfiles-created symlink, the
# caddy-readable snippet dir under /var/lib/claude-box-sites, the
# effectiveSudoAllowlist reload rule, and the /run/wrappers PATH addition
# that makes the setuid sudo wrapper resolvable in the agent unit's shell.
#
# lib.mkForce-swaps the top-level Caddyfile for a minimal one that keeps the
# `import` line (no ACME in the sandbox); the module's own terminal blocks
# aren't exercised here — the fail2ban test covers auth-side wiring.
{ claude-box }:
{
  name = "claude-box-self-serve-domain";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ claude-box ];
    virtualisation.memorySize = 2048;
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
      };
    };
    system.stateVersion = "25.05";

    # A placeholder password hash so the auth-secrets prep unit has something
    # to read; this test doesn't exercise the terminal vhost.
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

    # Bare-bones Caddyfile that keeps the module's per-user `import`. The
    # sandbox has no ACME, so we don't include the module's real terminal
    # vhost here — the self-serve snippet below brings its own `tls internal`.
    # Caddyfile globs cap at ONE `*`, so this stays per-user (matches the
    # module).
    services.caddy.configFile = lib.mkForce (pkgs.writeText "Caddyfile" ''
      import /var/lib/claude-box-sites/agent/*.caddy
    '');
  };

  nodes.client = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("caddy.service")
    client.wait_for_unit("multi-user.target")
    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]

    # The tmpfiles-created symlink from ~agent/sites into the caddy-readable dir.
    machine.succeed("test -L /home/agent/sites")
    machine.succeed(
        '[ "$(readlink /home/agent/sites)" = /var/lib/claude-box-sites/agent ]'
    )

    # Perms: 0750 agent:caddy. The user writes; caddy reads by group.
    machine.succeed(
        "stat -c '%U:%G %a' /var/lib/claude-box-sites/agent | grep -x 'agent:caddy 750'"
    )

    # The agent writes a new vhost snippet through the ~/sites symlink — never
    # touches /var/lib directly. `tls internal` sidesteps ACME in the sandbox.
    machine.succeed(
        "sudo -u agent tee /home/agent/sites/mysite.caddy > /dev/null <<'CFG'\n"
        "mysite.test {\n"
        "  tls internal\n"
        "  respond \"hello from mysite\" 200\n"
        "}\n"
        "CFG"
    )

    # File landed inside the caddy-readable dir (symlink target), owned by agent.
    machine.succeed(
        "stat -c '%U' /var/lib/claude-box-sites/agent/mysite.caddy | grep -x agent"
    )

    # /run/wrappers must be on the agent unit's PATH — it holds the setuid
    # sudo wrapper, without which shells started by the agent CLI can't
    # invoke sudo even though the sudoers rule permits the command.
    machine.succeed(
        "systemctl show claude-box-agent --property=Environment "
        "| grep -q '/run/wrappers/bin'"
    )

    # Reload caddy via the sudo rule (NOPASSWD).
    machine.succeed(
        "sudo -u agent -H bash -lc "
        "'sudo -n systemctl reload caddy.service'"
    )
    machine.wait_until_succeeds("systemctl is-active caddy.service", timeout=20)

    # New vhost actually serves.
    curl = f"curl -sk --resolve mysite.test:443:{machine_ip}"
    client.wait_until_succeeds(f"{curl} https://mysite.test/ | grep -q 'hello from mysite'", timeout=30)
  '';
}
