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

## Rolling temperature averages

Temperature rules in `~/Library/Application Support/Stats/fan-curve.json` can opt into an in-memory rolling average with `averageSeconds`:

```json
{
  "sensorName": "Average CPU",
  "averageSeconds": 30,
  "points": [
    { "temp": 55, "speed": 2400 },
    { "temp": 75, "speed": 4500 }
  ]
}
```

The window must be between 1 and 3600 seconds. Omitting `averageSeconds` keeps the rule on the live reading. Each configured average is also published as a computed temperature sensor, such as `Average CPU (30s average)`, for widgets, notifications, and other sensor views.

## Usage-based fan curves

Add `usageRules` alongside `temperatureRules` inside any profile in `fan-curve.json`. Each rule uses a `source` of `cpu`, `gpu`, or `ram` and percentage-based `usage` points (0–100). Speeds are RPM, and the highest target across temperature, usage, and matching app rules wins:

```json
{
  "activeProfile": "Balanced",
  "profiles": [{
    "name": "Balanced",
    "temperatureRules": [{
      "sensorName": "Average CPU",
      "points": [{ "temp": 55, "speed": 2400 }, { "temp": 85, "speed": 5000 }]
    }],
    "usageRules": [{
      "source": "cpu",
      "points": [{ "usage": 20, "speed": 2400 }, { "usage": 80, "speed": 5000 }]
    }],
    "appRules": []
  }]
}
```

A profile may use only usage rules, or combine them with temperature rules. Usage comes from the enabled CPU, GPU, and RAM modules' live readers; `gpu` follows the GPU selected in Stats. If any configured source is unavailable or stale, custom fan control stops and automatic control is restored. An app rule does not bypass this safety check. Points are linearly interpolated and clamped at their endpoints, just like temperature points.
