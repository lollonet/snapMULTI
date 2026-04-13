#!/usr/bin/env bash
# Install git hooks for local CI checks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Installing git hooks..."

# Copy pre-push hook
cp "$SCRIPT_DIR/git-hooks/pre-push" "$PROJECT_DIR/.git/hooks/pre-push"
chmod +x "$PROJECT_DIR/.git/hooks/pre-push"

echo "✓ Pre-push hook installed"
echo ""
echo "The hook will run automatically before every git push."
echo "To bypass: git push --no-verify"
