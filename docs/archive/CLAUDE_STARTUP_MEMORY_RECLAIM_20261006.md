# Claude startup stalled by aggregate memory reclaim (2026-10-06)

Mission `e19e93c0-6942-4f16-ba04-9adfcafed915` accepted the operator's
status request at 08:13:54 UTC. Three launch attempts emitted zero native
stream events and expired after 90 seconds each. No inference request reached
CLIProxyAPI. The message was not lost.

The launcher binary passed an independent PTY startup check. The failing
mission scope instead spent almost all CPU time in the kernel. At diagnosis:

- `missions.slice` memory usage was 36,520,824,832 bytes, above its 34 GiB
  `MemoryHigh`; memory PSI was approximately 95% some / 90% full.
- The individual new mission scope had only a few MiB resident and no local
  memory-limit events. Its ancestor forced allocation stalls.
- Two retained host background Lean builds consumed approximately 20 GiB and
  14 GiB, running for 14 and 11 hours. Their missions were awaiting_user and
  blocked. Host scopes intentionally preserve detached work between turns;
  indiscriminately reaping them would destroy legitimate background work.
- The host still had roughly 25 GiB available. Increasing the Claude startup
  timeout or changing credentials would not correct ancestor reclaim.

## Production correction

The aggregate soft limit was persistently raised to 38 GiB:

```sh
systemctl set-property missions.slice MemoryHigh=38G
systemctl show missions.slice -p MemoryHigh -p MemoryMax
```

The strict 40 GiB `MemoryMax`, 8 GiB swap cap, CPU and I/O limits remain in
force, reserving approximately 22 GiB of physical RAM for the host/control
plane. This is an operational setting, not a backend binary change.

After this change the same mission emitted Claude native stream events,
executed tools, and durably answered the requested status at approximately
08:45 UTC. The agent then stopped its stalled 16-hour / 20 GiB build, freeing
additional capacity. No workspace was deleted. The temporary diagnostic
CLI-path override was restored and its wrapper removed.

## Follow-up operations

Check aggregate PSI alongside usage when launch timeouts recur:

```sh
cat /sys/fs/cgroup/missions.slice/memory.current
cat /sys/fs/cgroup/missions.slice/memory.pressure
cat /sys/fs/cgroup/missions.slice/memory.events
```

A high `MemoryHigh` event count and sustained PSI with free host RAM identify
aggregate reclaim, not provider latency. The 38 GiB soft limit still throttles
if background workloads grow past it. Inspect retained builds and their mission
owners; stop a stalled build through its owning agent or explicitly pause its
mission, rather than blindly killing every host scope. Large proof builds should
use the existing Spark offload path. Do not remove the strict aggregate cap.
