# zig-zag development tasks

# Default recipe - show available commands
default:
    @just --list

# === Build ===

# Build debug executable
build:
    zig build exec:dbg

# Build release executable
build-release:
    zig build exec:rls

# Build debug shared library (for macOS app)
lib:
    zig build lib:dbg

# Build release shared library
lib-release:
    zig build lib:rls

# === Run ===

# Run the server (debug)
run:
    zig build run

# Run with custom config
run-config config:
    zig build run -- --config {{config}}

# === Test ===

# Run all tests
test:
    zig build test

# === macOS App ===

# Build macOS app (debug)
app: lib
    xcodebuild -project ui/macos/zig-zag/zig-zag.xcodeproj \
        -scheme zig-zag \
        -configuration Debug \
        -derivedDataPath build \
        -arch arm64 \
        clean build

# Build macOS app (release)
app-release: lib-release
    xcodebuild -project ui/macos/zig-zag/zig-zag.xcodeproj \
        -scheme zig-zag \
        -configuration Release \
        -derivedDataPath build \
        -arch arm64 \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        clean build
    codesign --force --deep --sign - "build/Build/Products/Release/zig-zag.app"

# Install macOS app to /Applications
install: app-release
    rm -rf /Applications/zig-zag.app
    cp -R "build/Build/Products/Release/zig-zag.app" /Applications/

# Create DMG for distribution
dmg: app-release
    rm -rf dmg-contents zig-zag-macos-app.dmg
    mkdir -p dmg-contents
    cp -R "build/Build/Products/Release/zig-zag.app" dmg-contents/
    hdiutil create -volname "zig-zag" -srcfolder dmg-contents -ov -format UDZO zig-zag-macos-app.dmg
    rm -rf dmg-contents

# === Clean ===

# Clean build artifacts
clean:
    rm -rf zig-out zig-cache .zig-cache build dmg-contents zig-zag-macos-app.dmg

# Clean only Xcode build
clean-xcode:
    rm -rf build

# === Release ===

# Get current version from version.txt (single source of truth)
@current-version:
    cat version.txt | tr -d '\n'

# Prepare release: bump version and create tag (bump: major, minor, patch)
release bump:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Get current version
    current=$(just current-version)
    echo "Current version: $current"
    
    # Parse version
    IFS='.' read -r major minor patch <<< "$current"
    
    # Bump version
    case "{{bump}}" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo "Error: bump must be 'major', 'minor', or 'patch'"
            exit 1
            ;;
    esac
    
    new_version="${major}.${minor}.${patch}"
    echo "New version: $new_version"
    
    # Update version.txt (single source of truth)
    echo "$new_version" > version.txt
    
    # Update Xcode project (both Debug and Release configs)
    sed -i '' "s/MARKETING_VERSION = $current;/MARKETING_VERSION = $new_version;/g" \
        ui/macos/zig-zag/zig-zag.xcodeproj/project.pbxproj
    
    # Commit and tag
    git add -A
    git commit -m "chore: bump version to $new_version"
    git tag "v$new_version"
    
    echo ""
    echo "✓ Version bumped to $new_version"
    echo "✓ Created tag v$new_version"
    echo ""
    echo "To push: git push origin main && git push origin v$new_version"

# Push release (after running 'just release')
push-release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(just current-version)
    git push origin main
    git push origin "v$version"
    echo "✓ Pushed main and tag v$version"

# === Utility ===

# Format Zig code
fmt:
    zig fmt src/

# Check code without building
check:
    zig build --summary all

# Show project structure
tree:
    @tree -I 'zig-out|zig-cache|.zig-cache|build|.git' -L 3
