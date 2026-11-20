# Live native mission writes

* Leaving the composer or losing text-input focus cancels preedit. Committed text stays in the draft. Activating Send after blur must not require another text edit.
* An unconfirmed Send retains its submission ID for a retry of the same draft on the same mission. Even if the mission is now running, that activation retries Send rather than stopping the turn. Core authorizes the caller before replaying a receipt; it must not append or dispatch the same submission again.
* Stop on a Core-local turn must tear down its harness process. An `interrupted` database row alone is insufficient evidence. Archive must persist across a Core restart.

On Linux, build `scripts/build_orb_bins.sh --only orb-core` and run `python3 lean/OrbDesktop/tests/live_writes.py` with Sway and wtype. The desktop sends through a loopback proxy which withholds the first successful Send reply. The observer reads Core directly and checks the submitted text, event ID, launch count, process lifetime via pidfd, and persisted archive for the created mission.
