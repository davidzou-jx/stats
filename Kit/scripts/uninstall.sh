#!/bin/sh

set -u

LEGACY_HELPER_LABELS="eu.exelban.Stats.SMC.Helper eu.exelban.Stats.SMC.Helper.Local"

stats_user_home="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    stats_user_home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
fi

run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

echo "Uninstalling Stats..."

run_as_user osascript -e 'quit app "Stats"' >/dev/null 2>&1 || true

for legacy_helper_label in $LEGACY_HELPER_LABELS; do
    if [ -e "/Library/LaunchDaemons/$legacy_helper_label.plist" ] || [ -e "/Library/PrivilegedHelperTools/$legacy_helper_label" ]; then
        echo "Removing legacy Stats SMC helper $legacy_helper_label (administrator privileges are required)..."
        sudo launchctl bootout "system/$legacy_helper_label" 2>/dev/null || true
        sudo launchctl unload "/Library/LaunchDaemons/$legacy_helper_label.plist" 2>/dev/null || true
        sudo rm -f "/Library/LaunchDaemons/$legacy_helper_label.plist"
        sudo rm -f "/Library/PrivilegedHelperTools/$legacy_helper_label"
    fi
done

for app in "/Applications/Stats.app" "$stats_user_home/Applications/Stats.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        sudo rm -rf "$app"
    fi
done

echo "Removing application data and preferences..."
rm -rf "$stats_user_home/Library/Application Support/Stats"
rm -rf "$stats_user_home/Library/Containers/eu.exelban.Stats.Widgets"
rm -rf "$stats_user_home/Library/Group Containers/"*.eu.exelban.Stats.widgets
run_as_user defaults delete eu.exelban.Stats >/dev/null 2>&1 || true
run_as_user defaults delete eu.exelban.Stats.Widgets >/dev/null 2>&1 || true
rm -f "$stats_user_home/Library/Preferences/eu.exelban.Stats.plist"
rm -f "$stats_user_home/Library/Preferences/eu.exelban.Stats.Widgets.plist"

echo "Stats has been uninstalled."
echo "The standalone FanController was not removed. Use its own uninstall script if needed."
