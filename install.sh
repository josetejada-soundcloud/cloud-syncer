#!/bin/bash

# ==============================================================================
# Cloud Syncer - Installation Script
# ==============================================================================

set -e

echo "🚀 Installing Cloud Syncer..."

# 1. Create the global scripts directory
CURSOR_SCRIPTS_DIR="$HOME/.cursor/scripts"
mkdir -p "$CURSOR_SCRIPTS_DIR"

# 2. Copy the sync script
echo "📦 Installing sync script to $CURSOR_SCRIPTS_DIR..."
cp cloud-sync.sh "$CURSOR_SCRIPTS_DIR/cloud-sync.sh"
chmod +x "$CURSOR_SCRIPTS_DIR/cloud-sync.sh"

# 3. Configure Cursor Global Tasks
CURSOR_USER_DIR="$HOME/Library/Application Support/Cursor/User"
TASKS_FILE="$CURSOR_USER_DIR/tasks.json"

echo "⚙️ Configuring Cursor tasks..."
mkdir -p "$CURSOR_USER_DIR"

if [ ! -f "$TASKS_FILE" ]; then
    # Create new tasks.json if it doesn't exist
    cat > "$TASKS_FILE" << 'EOF'
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Sync to Cloud IDEs",
            "type": "shell",
            "command": "/Users/${USER}/.cursor/scripts/cloud-sync.sh",
            "options": {
                "env": {
                    "ACTIVE_FILE_DIR": "${fileDirname}"
                }
            },
            "presentation": {
                "reveal": "always",
                "panel": "new",
                "focus": true,
                "clear": true
            },
            "problemMatcher": []
        }
    ]
}
EOF
else
    # If it exists, we just tell the user to add it manually to avoid breaking their custom tasks
    echo "⚠️ You already have a custom tasks.json file."
    echo "Please manually add the following task to $TASKS_FILE:"
    echo '
        {
            "label": "Sync to Cloud IDEs",
            "type": "shell",
            "command": "~/.cursor/scripts/cloud-sync.sh",
            "options": {
                "env": {
                    "ACTIVE_FILE_DIR": "${fileDirname}"
                }
            },
            "presentation": {
                "reveal": "always",
                "panel": "new",
                "focus": true,
                "clear": true
            }
        }'
fi

# 4. Configure Keybindings
KEYBINDINGS_FILE="$CURSOR_USER_DIR/keybindings.json"
echo "⌨️ Configuring keyboard shortcuts..."

if [ ! -f "$KEYBINDINGS_FILE" ]; then
    cat > "$KEYBINDINGS_FILE" << 'EOF'
[
    {
        "key": "cmd+shift+s",
        "command": "workbench.action.tasks.runTask",
        "args": "Sync to Cloud IDEs"
    }
]
EOF
else
    echo "⚠️ You already have a custom keybindings.json file."
    echo "Please manually add the following binding to $KEYBINDINGS_FILE:"
    echo '
    {
        "key": "cmd+shift+s",
        "command": "workbench.action.tasks.runTask",
        "args": "Sync to Cloud IDEs"
    }'
fi

echo ""
echo "🎉 Installation Complete!"
echo "👉 To use the tool, open any file in a Git repository inside Cursor and press: Cmd + Shift + S"
