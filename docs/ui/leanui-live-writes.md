# Live native mission writes

* Leaving the composer or losing text-input focus cancels preedit. Committed text stays in the draft. Activating Send after blur must not require another text edit.
* An unconfirmed Send retains its submission ID for a retry of the same draft on the same mission. Even if the mission is now running, that activation retries Send rather than stopping the turn. Core authorizes the caller before replaying a receipt; it must not append or dispatch the same submission again.
* Stop on a Core-local turn must tear down its harness process. An `interrupted` database row alone is insufficient evidence. Archive must persist across a Core restart.
* If Stop wins while the first checkpoint is still running, releasing the checkpoint must not start the stopped generation. If a native message receipt cannot be finalized after dispatch, restarting Core must retain an uncertain result for that key rather than repeating the event or launch.
* A Send delayed after its event was stored must activate only the generation observed at admission. A warm child that does not read its prompt must still be stoppable. `python3 lean/OrbDesktop/tests/write_windows.py` exercises both orderings and the preceding checkpoint and restart cases against an isolated Core.

On Linux, build `scripts/build_orb_bins.sh --only orb-core` and run `python3 lean/OrbDesktop/tests/live_writes.py` with Sway and wtype. The desktop sends through a loopback proxy which withholds the first successful Send reply. The observer reads Core directly and checks the submitted text, event ID, launch count, process lifetime via pidfd, and persisted archive for the created mission.
