# VM test for protectMemory (issue 62): zram swap is active, earlyoom
# runs, the agent unit carries the raised OOMScoreAdjust — and, the actual
# incident scenario, a runaway memory hog gets killed by earlyoom while
# the box stays responsive, instead of the no-swap refault livelock that
# froze a 2 GB CFN box (Caddy, sshd and SSM included) for six hours.
#
# Pass to pkgs.testers.runNixOSTest.
{ claude-box }:
{
  name = "claude-box-memory-protection";
  node.pkgsReadOnly = false;

  nodes.machine = { pkgs, ... }: {
    imports = [ claude-box ];
    virtualisation.memorySize = 2048;
    services.claude-box = {
      enable = true;
      agent = "claude";
      users.agent = { };
    };
    system.stateVersion = "25.05";
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("claude-box-agent.service")
    machine.wait_for_unit("earlyoom.service")

    # zram swap is active and sized to RAM (memoryPercent = 100)
    print(machine.succeed("swapon --show"))
    machine.succeed("swapon --show=NAME --noheadings | grep -q zram0")

    # the zram sysctl tuning landed
    assert machine.succeed("sysctl -n vm.swappiness").strip() == "180"
    assert machine.succeed("sysctl -n vm.page-cluster").strip() == "0"

    # the agent unit's main process runs with the raised OOM score
    main_pid = machine.succeed(
        "systemctl show -p MainPID --value claude-box-agent.service"
    ).strip()
    assert main_pid != "0", "agent unit has no main PID"
    adj = machine.succeed(f"cat /proc/{main_pid}/oom_score_adj").strip()
    assert adj == "500", f"agent oom_score_adj = {adj}, want 500"

    # Provoke the incident: an unbounded allocator that on a swapless box
    # would livelock the whole VM. tail buffers all of /dev/zero in RAM;
    # transient unit so the hog is not a child of the test's own shell.
    machine.execute(
        "systemd-run --unit=memhog sh -c 'tail /dev/zero > /dev/null'"
    )

    # earlyoom notices the pressure and SIGTERM/SIGKILLs the hog...
    machine.wait_until_succeeds(
        "journalctl -u earlyoom.service | grep -E 'sending SIG(TERM|KILL) to process' | grep -q tail",
        timeout=180,
    )
    machine.wait_until_fails("pgrep -x tail", timeout=60)

    # ...and the box came through responsive, management plane intact.
    machine.succeed("systemctl is-active earlyoom.service")
    machine.succeed("systemctl is-active claude-box-agent.service")
    print(machine.succeed("journalctl -u earlyoom.service | tail -20"))
  '';
}
