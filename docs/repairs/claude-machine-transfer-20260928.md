# Claude Code machine-transfer repair (2026-09-28)

The node transfer endpoint only checked Grok, Codex and OpenCode. Claude was
installed but omitted. The continuation planner also rejected Claude, so merely
adding a menu option would not have made the first post-transfer turn work.

Changes:

- Advertise the `claude` executable as backend `claudecode`; new node capability
  responses use version 2.
- For version 1 nodes, supplement the missing entry only when their authenticated
  software inventory reports an installed Claude executable and a nonempty
  version. Apply the same check during discovery and destination validation.
  Version 2 responses remain authoritative. This permits rolling upgrades without
  restarting active node jobs.
- Allocate a UUID for each new remote Claude session, save it under the run fence,
  pass `--session-id` on launch and `--resume` for subsequent messages.
- Preserve the selected harness/model as dynamic options are mounted in Orb.

Validation:

- 18 frontend transfer tests pass, including Claude selection for six
  picker destinations, including the administration entry.
- Node capability mapping regression passes; legacy inventory evidence and
  authoritative-version behavior pass.
- Integration tests cover new remote Claude sessions and transferred sessions:
  same mission and native session across turns, correct destination cwd, portable
  context injected once, and no repeated history on native resume.
- Production transfer discovery lists Claude for Core and all seven node
  endpoints. The administration node remains cordoned.
- Ashur's idle node service was upgraded after cordoning and checking its job
  store; its version 2 endpoint directly advertises Claude. Other nodes work via
  verified inventory without a node restart.
- Two-turn live memory checks passed on Ashur, Babylon, Nippur, Sepolia,
  DGX Spark and old-agent: the second prompt did not repeat the random marker,
  and each resumed session returned it correctly. All six retained their native
  session UUID and exited successfully. Results are recorded in
  `/root/.cache/claude-transfer-canaries.json` on Core.
- Verity retained job `1e066c78-1d00-4b82-a349-b8c0d1b8a297` across the guarded
  production backend deployment.

The administration cordon was not changed. This validates infrastructure and
continuity, not unlimited provider availability or every possible project setup.
