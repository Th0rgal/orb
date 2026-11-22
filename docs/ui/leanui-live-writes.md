# Live native mission writes

* Leaving the composer or losing text-input focus cancels preedit. Committed text stays in the draft. Activating Send after blur must not require another text edit.
* An unconfirmed Send retains its submission ID for a retry of the same draft on the same mission. Even if the mission is now running, that activation retries Send rather than stopping the turn. Core authorizes the caller before replaying a receipt; it must not append or dispatch the same submission again.
* Stop on a Core-local turn must tear down its harness process. An `interrupted` database row alone is insufficient evidence. Archive must persist across a Core restart.
* If Stop wins while the first checkpoint is still running, releasing the checkpoint must not start the stopped generation. If a native message receipt cannot be finalized after dispatch, restarting Core must retain an uncertain result for that key rather than repeating the event or launch.
* A Send delayed after its event was stored must activate only the generation observed at admission. A warm child that does not read its prompt must still be stoppable. `python3 lean/OrbDesktop/tests/write_windows.py` exercises both orderings and the preceding checkpoint and restart cases against an isolated Core.

A remote follow-up refused before managed provisioning starts may reuse its submission ID. Once provisioning has started, a failure can have external effects, so a retry keeps the original claim.
Both remote follow-up endpoints persist the user’s event before submitting the turn. If the event write fails, Core returns a storage error and sends no job to the node.

On Linux, build `scripts/build_orb_bins.sh --only orb-core` and run `python3 lean/OrbDesktop/tests/live_writes.py` with Sway and wtype. The desktop sends through a loopback proxy which withholds the first successful Send reply. The observer reads Core directly and checks the submitted text, event ID, launch count, process lifetime via pidfd, and persisted archive for the created mission.

Core-local activation allocates a generation before PID registration. Archive can invalidate a pending launch while the mission is idle. Once the status is active, Archive returns `409 mission_running` even before a PID is registered and even with zero run rows (`archive-registration`). A newer activation can supersede an unregistered launch. An older completion must not remove the newer PID or settle its status. Stop retains ownership of each child until exit: a concurrent Archive must receive `409 mission_running` even after Stop has written `interrupted` (`stop-archive`). For warm Claude the reader owns both pipe descriptors; Stop signals the process. The `fd` case in `write_windows.py` requires `strace` and checks the actual stdout pipe during Stop.

Retiring warm children remain visible to Archive until exit. Transcript writes from a harness are conditional on its active generation. An occupied local one-shot returns a replayable `409 local_run_busy` before recording a second user message. LeanUI keeps the draft for an explicit new submission once idle (`live_writes.py busy`); an uncertain response retains its original key.

For a running remote mission, both follow-up endpoints confirm queueing only after the queue transaction commits. If the transaction fails, the draft can be retried with the same message ID. Repeated delivery of that ID leaves one queued item.
