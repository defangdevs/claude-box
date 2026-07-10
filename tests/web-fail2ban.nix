# VM test for the web.fail2ban jail: a client that repeatedly fails the
# terminal's basic auth gets banned at the firewall, while credential-less
# 401s (what a browser gets before showing the password prompt) don't count.
#
# Pass to pkgs.testers.runNixOSTest. lib.mkForce-overrides
# services.caddy.configFile with a minimal `tls internal` file (no ACME in
# the sandbox). Doesn't exercise ttyd — only caddy + fail2ban — so it stays
# green even when ttyd is broken in nixpkgs.
{ claude-box }:
{
  name = "claude-box-web-fail2ban";
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

    # Materialize the password hash (subshell so the umask doesn't leak).
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

    # Swap the module-managed Caddyfile for a minimal `tls internal` one; the
    # sandbox has no ACME. Same env placeholder the module wires up, so the
    # claude-web-auth-secrets prep still feeds this vhost.
    services.caddy.configFile = lib.mkForce (pkgs.writeText "Caddyfile" ''
      box.test {
        log
        tls internal
        route {
          basic_auth {
            agent {$WEB_PASSWORD_HASH_AGENT}
          }
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
    machine.wait_for_unit("fail2ban.service")
    client.wait_for_unit("multi-user.target")

    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    client_ip = client.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]
    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # Correct password works and doesn't score against the jail
    client.succeed(f"{curl} -u agent:testpassword https://box.test/ | grep -q ok")

    # Five wrong-password attempts trip maxretry
    for i in range(5):
        client.succeed(f"{curl} -o /dev/null -u agent:wrong{i} https://box.test/")

    machine.wait_until_succeeds(
        f"fail2ban-client status claude-web-auth | grep -q '{client_ip}'",
        timeout=60,
    )

    # Banned: connection no longer completes
    client.fail(f"{curl} -m 5 -o /dev/null -u agent:testpassword https://box.test/")

    # The credential-less 401 a browser gets before prompting is NOT counted
    print(machine.succeed("fail2ban-client status claude-web-auth"))
  '';
}
