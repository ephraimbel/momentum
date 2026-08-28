#!/bin/zsh
# Relaunch momentum on the data-rich screenshot sim (light mode, 9:41 status bar). Pass a page
# arg to land somewhere: --plan-tab · --progress-tab · --progress-health · --fuel-tab · --profile-tab · --coach
# For the 100 / Primed iridescent readiness shot add: --health-recovery-primed --readiness-primed
UD=BE716EA7-436F-4DCB-ACC8-4777AAE5E623
xcrun simctl boot $UD 2>/dev/null; xcrun simctl ui $UD appearance light
xcrun simctl status_bar $UD override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
open -a Simulator --args -CurrentDeviceUDID $UD
xcrun simctl terminate $UD com.ephraimbel.momentum.app 2>/dev/null
xcrun simctl launch $UD com.ephraimbel.momentum.app --seed-demo --seed-dense-history --seed-plan-long --seed-route-history --seed-fuel-history --seed-fuel-today --health-recovery-demo --awards-quiet --seed-track-run "$@"
