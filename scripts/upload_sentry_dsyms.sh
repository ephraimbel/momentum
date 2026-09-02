#!/bin/sh

# Symbolicate production crashes without weakening Debug/test builds or uploading source code.
# SENTRY_AUTH_TOKEN comes from the ignored Secrets.xcconfig and is never copied into Info.plist.

if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

# Release simulator builds are useful for catching optimization-only compiler failures, but their
# symbols cannot symbolicate a production crash and would only consume Sentry processing/quota.
if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
    exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "warning: Sentry dSYM upload skipped — SENTRY_AUTH_TOKEN is not configured"
    exit 0
fi

if [ -x /opt/homebrew/bin/sentry-cli ]; then
    SENTRY_CLI=/opt/homebrew/bin/sentry-cli
elif command -v sentry-cli >/dev/null 2>&1; then
    SENTRY_CLI=$(command -v sentry-cli)
else
    echo "warning: Sentry dSYM upload skipped — install getsentry/tools/sentry-cli"
    exit 0
fi

export SENTRY_ORG=momentum-l6
export SENTRY_PROJECT=momentum-ios

# Deliberately omit --include-sources: readable symbols are useful; uploading the source tree is not.
if ! "$SENTRY_CLI" debug-files upload "$DWARF_DSYM_FOLDER_PATH" --wait >/dev/null; then
    echo "warning: Sentry dSYM upload failed — the archive remains usable; upload its dSYMs manually"
fi
