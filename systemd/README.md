# Screenshot expiry

After deploying the current `Rail.qml`, run
`bash systemd/install-paste-cleanup.sh` as the desktop user and the VM user. The
same files are installed on both hosts; no Cockpit or agent daemon restart is
needed for the timer.

The hourly user timer deletes files in `~/.cache/heidr-pastes` whose
modification time is older than 24 hours. Reads do not extend retention. This is
age-based, not an acknowledgement that an agent has consumed the screenshot. Old
transcript references will therefore stop resolving after expiry.

The `.sequence` counter is retained and locked while allocating image numbers.
Installation seeds it from existing filenames before the first cleanup, so
expiry does not cause number reuse. Project-local legacy `.heidr-pastes` folders
are not included in this cleanup.

Verify with `systemctl --user list-timers cockpit-paste-clean.timer` and
`systemctl --user status cockpit-paste-clean.service`.
