#!/bin/bash
# MyndAIX Bridge — Build Verification Gate
# Usage: ./verify-build.sh <project_path> <message_file>
#
# Runs build verification before a task is marked as "review".
# Returns exit 0 if build passes, non-zero if it fails.
# On failure, appends build errors to the message file.

PROJECT_PATH="$1"
MESSAGE_FILE="$2"

if [ -z "$PROJECT_PATH" ] || [ -z "$MESSAGE_FILE" ]; then
    echo "Usage: verify-build.sh <project_path> <message_file>"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Project path not found: $PROJECT_PATH"
    exit 1
fi

echo "Running build verification for: $PROJECT_PATH"

BUILD_OUTPUT=""
BUILD_EXIT=0

if [ -f "$PROJECT_PATH/Package.swift" ]; then
    echo "Detected: Swift Package"
    BUILD_OUTPUT=$(swift build --package-path "$PROJECT_PATH" 2>&1)
    BUILD_EXIT=$?
elif ls "$PROJECT_PATH"/*.xcworkspace 1>/dev/null 2>&1; then
    echo "Detected: Xcode Workspace"
    SCHEME=$(basename "$PROJECT_PATH")
    BUILD_OUTPUT=$(xcodebuild -workspace "$PROJECT_PATH"/*.xcworkspace -scheme "$SCHEME" -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -30)
    BUILD_EXIT=${PIPESTATUS[0]}
elif ls "$PROJECT_PATH"/*.xcodeproj 1>/dev/null 2>&1; then
    echo "Detected: Xcode Project"
    SCHEME=$(basename "$PROJECT_PATH")
    BUILD_OUTPUT=$(xcodebuild -project "$PROJECT_PATH"/*.xcodeproj -scheme "$SCHEME" -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -30)
    BUILD_EXIT=${PIPESTATUS[0]}
elif [ -f "$PROJECT_PATH/package.json" ]; then
    echo "Detected: Node.js project"
    BUILD_OUTPUT=$(cd "$PROJECT_PATH" && npm run build 2>&1)
    BUILD_EXIT=$?
elif [ -f "$PROJECT_PATH/Cargo.toml" ]; then
    echo "Detected: Rust project"
    BUILD_OUTPUT=$(cd "$PROJECT_PATH" && cargo build 2>&1)
    BUILD_EXIT=$?
elif [ -f "$PROJECT_PATH/go.mod" ]; then
    echo "Detected: Go project"
    BUILD_OUTPUT=$(cd "$PROJECT_PATH" && go build ./... 2>&1)
    BUILD_EXIT=$?
else
    echo "Unknown project type, skipping build verification"
    exit 0
fi

if [ $BUILD_EXIT -eq 0 ]; then
    echo "Build passed"
else
    echo "Build failed (exit code: $BUILD_EXIT)"
    if [ -n "$MESSAGE_FILE" ] && [ -f "$MESSAGE_FILE" ]; then
        {
            echo ""
            echo "## Build Verification FAILED"
            echo ""
            echo "**Exit code:** $BUILD_EXIT"
            echo ""
            echo '```'
            echo "$BUILD_OUTPUT" | tail -40
            echo '```'
        } >> "$MESSAGE_FILE"
    fi
fi

exit $BUILD_EXIT
