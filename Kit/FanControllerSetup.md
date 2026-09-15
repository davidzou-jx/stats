# FanController setup for Stats

Stats uses the standalone `fancontrold` service for fan writes. The app does not bundle, register, or update a privileged helper.

## Install the local controller

1. In Stats, select Automatic fan control and quit the app.
2. Build and stage the sibling `fan-controller` project:

       cd /path/to/fan-controller
       swift test
       ./scripts/stage.sh

3. Verify that fan control is automatic, then remove any legacy Stats SMC helper:

       sudo launchctl bootout system/eu.exelban.Stats.SMC.Helper 2>/dev/null || true
       sudo launchctl bootout system/eu.exelban.Stats.SMC.Helper.Local 2>/dev/null || true
       sudo rm -f /Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist
       sudo rm -f /Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.Local.plist
       sudo rm -f /Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper

   Do not continue unless both `launchctl print system/eu.exelban.Stats.SMC.Helper` and `launchctl print system/eu.exelban.Stats.SMC.Helper.Local` report that the services cannot be found.
4. Install the staged service for your account:

       cd dist/FanController
       sudo ./scripts/install.sh --allow-user "$USER"

5. Verify the service before opening Stats:

       fanctl doctor
       fanctl status

The installer uses ad-hoc signatures by default, so an Apple Developer account is not required for a local build. The root-owned launch daemon authenticates clients by Unix user ID and grants only one expiring control lease at a time.

For live acceptance, rollback, and conflict-removal steps, read `docs/SWITCHOVER.md` in the FanController distribution.
