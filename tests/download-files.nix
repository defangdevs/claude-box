# VM test for issue #132: each web user gets a ~/downloads file-drop directory
# served — behind the terminal's basic auth — at /<user>/downloads/, so an
# agent can hand a file it produced to the controlling user as a full URL.
#
# Exercises: the tmpfiles-created backing dir (0750 agent:caddy) under
# /var/lib/agent-box-downloads and its ~/downloads symlink; caddy reaching a
# file the agent dropped there (caddy traverses by its group, reads by the
# file's world-read bit — the exact model the ~/sites snippet dir relies on,
# and why caddy's ProtectHome=true is a non-issue); and the auth gate (a
# credential-less request 401s, the right password serves the bytes).
#
# Like the fail2ban/self-serve tests, this lib.mkForce-swaps the module's
# ACME Caddyfile for a `tls internal` one — the sandbox has no ACME. The
# swapped-in vhost reproduces the module's downloads handle (basic_auth ->
# strip_prefix -> file_server); the flake's `download-route` eval check
# separately asserts the module's real Caddyfile emits that same block.
{ agent-box }:
{
  name = "agent-box-download-files";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, lib, ... }: {
    imports = [ agent-box ];
    virtualisation.memorySize = 2048;
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
      };
    };
    system.stateVersion = "25.05";

    # Materialize the password hash (subshell so the umask doesn't leak).
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

    # Minimal `tls internal` vhost reproducing the module's downloads handle.
    # Same $WEB_PASSWORD_HASH_AGENT placeholder the module wires up, so the
    # agent-web-auth-secrets prep still feeds this vhost. file_server serves
    # the caddy-readable backing dir the tmpfiles rule created.
    services.caddy.configFile = lib.mkForce (pkgs.writeText "Caddyfile" ''
      box.test {
        log
        tls internal
        handle /agent/downloads/* {
          route {
            basic_auth {
              agent {$WEB_PASSWORD_HASH_AGENT}
            }
            uri strip_prefix /agent/downloads
            root * /var/lib/agent-box-downloads/agent
            file_server browse
          }
        }
        handle {
          respond "terminal" 200
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
    client.wait_for_unit("multi-user.target")
    machine_ip = machine.succeed("ip -4 -o addr show eth1 | head -1").split()[3].split("/")[0]

    # The tmpfiles-created symlink from ~agent/downloads into the backing dir.
    machine.succeed("test -L /home/agent/downloads")
    machine.succeed(
        '[ "$(readlink /home/agent/downloads)" = /var/lib/agent-box-downloads/agent ]'
    )

    # Perms: 0750 agent:caddy, same as the ~/sites snippet dir — the user
    # writes, caddy reaches files by its group + their world-read bit.
    machine.succeed(
        "stat -c '%U:%G %a' /var/lib/agent-box-downloads/agent | grep -x 'agent:caddy 750'"
    )

    # The agent drops a file through the ~/downloads symlink (never touches
    # /var/lib directly), exactly as AGENTS.md instructs.
    machine.succeed(
        "sudo -u agent tee /home/agent/downloads/report.txt > /dev/null <<'EOF'\n"
        "hello from the box\n"
        "EOF"
    )
    # Default umask leaves it world-readable, which is what lets caddy read it.
    machine.succeed(
        "stat -c '%U %a' /var/lib/agent-box-downloads/agent/report.txt | grep -x 'agent 644'"
    )

    curl = f"curl -sk --resolve box.test:443:{machine_ip}"

    # A credential-less request is refused (401) — nothing is served anonymously.
    client.succeed(
        f"{curl} -o /dev/null -w '%{{http_code}}' https://box.test/agent/downloads/report.txt | grep -x 401"
    )

    # With the right password the file downloads intact.
    client.wait_until_succeeds(
        f"{curl} -u agent:testpassword https://box.test/agent/downloads/report.txt | grep -q 'hello from the box'",
        timeout=30,
    )

    # The bare directory is a browsable index listing the dropped file.
    # Capture the (multi-KB) listing to a file before grepping: piping a large
    # body into `grep -q` makes grep close the pipe on first match, and the
    # resulting curl write-error (exit 23) trips the driver's pipefail even
    # though the match succeeded.
    client.succeed(
        f"{curl} -u agent:testpassword https://box.test/agent/downloads/ -o /tmp/index.html"
    )
    client.succeed("grep -q report.txt /tmp/index.html")
  '';
}
