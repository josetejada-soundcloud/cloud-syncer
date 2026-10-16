#!/bin/bash

# ==============================================================================
# Cloud Syncer
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# Ensure we are running the git commands in the directory of the currently active file
if [ -n "$ACTIVE_FILE_DIR" ]; then
    cd "$ACTIVE_FILE_DIR"
    
    # Find the root of the git repository for this file
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$GIT_ROOT" ]; then
        cd "$GIT_ROOT"
    else
        echo "❌ ERROR: The currently active file is not inside a Git repository."
        echo "Current directory: $(pwd)"
        exit 1
    fi
else
    echo "❌ ERROR: Could not determine the active file directory."
    echo "Make sure you have a file open and focused in the editor before running the sync."
    exit 1
fi

echo "🔄 Starting Local-to-Cloud Sync..."

# --- 1. Get Git Context ---
# Check if we are actually in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "❌ ERROR: You are not inside a Git repository."
    echo "Current directory: $(pwd)"
    exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
REPO_NAME=$(basename -s .git `git config --get remote.origin.url`)

echo "📍 Current Branch: $CURRENT_BRANCH"
echo "📁 Repository: $REPO_NAME"

# --- 2. Pre-Flight Check: Dataform State ---
# Before we touch local Git, let's check if Dataform has uncommitted changes.
# If it does, AND we have local changes, we abort immediately to prevent a two-way sync nightmare.

# Define Dataform variables
# These can be customized per-user via environment variables or edited directly here
DATAFORM_PROJECT="${DATAFORM_PROJECT:-YOUR_GCP_PROJECT_ID}" 
DATAFORM_LOCATION="${DATAFORM_LOCATION:-europe-west1}" 
DATAFORM_REPOSITORY="${DATAFORM_REPOSITORY:-YOUR_DATAFORM_REPOSITORY}"

# Get Git User Info
GIT_USER_NAME=$(git config user.name || echo "Cloud Syncer")
GIT_USER_EMAIL=$(git config user.email || echo "cloud-syncer@example.com")
# We use the branch name as the workspace name to keep things isolated and clean
# Dataform workspace IDs must contain only lowercase letters, numbers, and hyphens.
DATAFORM_WORKSPACE=$(echo "$CURRENT_BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Get auth token
AUTH_TOKEN=$(gcloud auth print-access-token 2>/dev/null)

if [[ -z "$AUTH_TOKEN" ]]; then
    echo "❌ ERROR: Could not get gcloud auth token. Are you logged in? Run 'gcloud auth login'."
    exit 1
fi

echo "🔍 Running pre-flight check on Dataform workspace..."

# We do a dry-run pull to see if Dataform will reject it due to uncommitted changes
DRY_PULL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"remoteBranch\": \"${CURRENT_BRANCH}\", \"author\": {\"name\": \"${GIT_USER_NAME}\", \"emailAddress\": \"${GIT_USER_EMAIL}\"}}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:pull")

DRY_PULL_STATUS=$(echo "$DRY_PULL_RESPONSE" | tail -n1)
DRY_PULL_BODY=$(echo "$DRY_PULL_RESPONSE" | sed '$d')

DATAFORM_HAS_CHANGES="false"
if echo "$DRY_PULL_BODY" | grep -q "Cannot pull when there are uncommitted changes"; then
    DATAFORM_HAS_CHANGES="true"
fi

# --- 3. Handle Local Changes (Cursor -> GitHub) ---
LOCAL_CHANGES_EXISTED="false"
if [[ -n $(git status -s) ]]; then
    LOCAL_CHANGES_EXISTED="true"
fi

# The Safety Catch: Abort immediately if BOTH have uncommitted changes
if [[ "$LOCAL_CHANGES_EXISTED" == "true" ]] && [[ "$DATAFORM_HAS_CHANGES" == "true" ]]; then
    echo "⚠️ DANGEROUS SYNC DETECTED!"
    echo "You have uncommitted changes in BOTH Cursor and Dataform at the same time."
    echo "To prevent a massive merge conflict, we need to discard the changes in one of the environments."
    echo ""
    echo "Which environment has the CORRECT changes that you want to KEEP?"
    echo "1) Cursor (Discard Dataform changes)"
    echo "2) Dataform (Discard Cursor changes)"
    echo "3) Abort sync and let me handle it manually"
    read -p "Enter your choice (1/2/3): " conflict_choice
    
    if [[ "$conflict_choice" == "1" ]]; then
        echo "🗑️ Discarding Dataform changes..."
        # To discard Dataform changes, we hit the reset endpoint
        RESET_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          -H "Authorization: Bearer $AUTH_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"clean\": true}" \
          "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:reset")
          
        RESET_STATUS=$(echo "$RESET_RESPONSE" | tail -n1)
        if [ "$RESET_STATUS" -eq 200 ] || [ "$RESET_STATUS" -eq 204 ]; then
            echo "✅ Dataform changes discarded successfully."
            
            # CRITICAL FIX: The :reset endpoint throws away changes, but it DOES NOT pull the latest
            # branch state. If the workspace was in a conflicted state (with merge markers),
            # :reset throws away the uncommitted markers, but the workspace is still technically "behind".
            # We must explicitly tell Dataform we no longer have uncommitted changes.
            DATAFORM_HAS_CHANGES="false"
        else
            echo "❌ ERROR: Failed to discard Dataform changes (HTTP $RESET_STATUS)."
            echo "Response: $(echo "$RESET_RESPONSE" | sed '$d')"
            exit 1
        fi
        
    elif [[ "$conflict_choice" == "2" ]]; then
        echo "🗑️ Discarding Cursor changes..."
        # To discard Cursor changes, we use git restore and clean
        git restore .
        git clean -fd
        echo "✅ Cursor changes discarded successfully."
        LOCAL_CHANGES_EXISTED="false"
        # Since we discarded local changes, we need to pull the Dataform changes down
        # But first, we need to commit them in Dataform and push them.
        
        echo "💾 Committing Dataform changes..."
        read -p "Do you want to add a custom commit message for Dataform changes? (y/N): " df_custom_msg_choice
        
        if [[ "$df_custom_msg_choice" =~ ^[Yy]$ ]]; then
            read -p "Enter your Dataform commit message: " df_commit_msg
            if [[ -z "$df_commit_msg" ]]; then
                echo "⚠️ Empty message provided. Falling back to default."
                df_commit_msg="chore: auto-sync from cloud IDE"
            fi
        else
            df_commit_msg="chore: auto-sync from cloud IDE"
        fi
        
        COMMIT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          -H "Authorization: Bearer $AUTH_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"author\": {\"name\": \"${GIT_USER_NAME}\", \"emailAddress\": \"${GIT_USER_EMAIL}\"}, \"commitMessage\": \"$df_commit_msg\"}" \
          "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:commit")
          
        COMMIT_STATUS=$(echo "$COMMIT_RESPONSE" | tail -n1)
        if [ "$COMMIT_STATUS" -eq 200 ]; then
            echo "✅ Successfully committed changes in Dataform."
            echo "🚀 Pushing Dataform changes to GitHub..."
            curl -s -X POST \
              -H "Authorization: Bearer $AUTH_TOKEN" \
              -H "Content-Type: application/json" \
              -d "{\"remoteBranch\": \"${CURRENT_BRANCH}\"}" \
              "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:push" > /dev/null
              
            echo "☁️ Pulling new Dataform changes to local Cursor..."
            git pull --rebase origin "$CURRENT_BRANCH"
            echo "🎉 SUCCESS: Dataform workspace '${DATAFORM_WORKSPACE}' successfully synced with branch '${CURRENT_BRANCH}'!"
            exit 0
        else
            echo "❌ ERROR: Failed to commit Dataform changes."
            exit 1
        fi
        
    else
        echo "🛑 Sync aborted. Nothing has been committed or pushed."
        exit 1
    fi
fi

# If we passed the safety catch, proceed with local commits
if [[ "$LOCAL_CHANGES_EXISTED" == "false" ]]; then
    echo "✅ No local changes to commit."
else
    echo "📦 Local changes detected."
    
    # Ask the user if they want a custom commit message
    read -p "Do you want to add a custom commit message? (y/N): " custom_msg_choice
    
    if [[ "$custom_msg_choice" =~ ^[Yy]$ ]]; then
        read -p "Enter your commit message: " commit_msg
        if [[ -z "$commit_msg" ]]; then
            echo "⚠️ Empty message provided. Falling back to default."
            commit_msg="chore: auto-sync from local IDE"
        fi
    else
        commit_msg="chore: auto-sync from local IDE"
    fi
    
    echo "📦 Staging local changes..."
    git add .
    
    echo "📝 Committing changes..."
    git commit -m "$commit_msg"
fi

# --- 3. Handle Remote Sync ---
# Check if the branch exists on the remote
REMOTE_EXISTS=$(git ls-remote --heads origin "$CURRENT_BRANCH")

if [[ -z "$REMOTE_EXISTS" ]]; then
    echo "🌱 Branch does not exist on remote. Pushing and setting upstream..."
    git push -u origin "$CURRENT_BRANCH"
else
    echo "☁️ Pulling latest changes from remote (rebase)..."
    
    # Attempt to pull and rebase. If it fails, catch the error.
    if ! git pull --rebase origin "$CURRENT_BRANCH"; then
        echo "❌ ERROR: Merge conflict detected during pull!"
        echo "⚠️ Aborting the automatic rebase to keep your workspace clean."
        git rebase --abort
        echo "👉 Please resolve the conflicts manually by running 'git pull' and fixing the files."
        exit 1
    fi

    echo "🚀 Pushing synced state to remote..."
    git push origin "$CURRENT_BRANCH"
fi

echo "✅ Git sync complete! Local and remote are mirrored."

# --- 4. Manage Dataform Workspace via GCP API ---
echo "🔄 Managing Dataform Workspace via GCP API..."

# 4a. Check if the workspace exists
WORKSPACE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}")

if [ "$WORKSPACE_CHECK" -eq 404 ]; then
    echo "🌱 Workspace '${DATAFORM_WORKSPACE}' does not exist. Creating it now..."
    
    # Create the workspace
    CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{}" \
      "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces?workspaceId=${DATAFORM_WORKSPACE}")
      
    CREATE_STATUS=$(echo "$CREATE_RESPONSE" | tail -n1)
    CREATE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')
    
    if [ "$CREATE_STATUS" -eq 200 ]; then
        echo "✅ Workspace created successfully!"
    else
        echo "❌ ERROR: Failed to create workspace (HTTP $CREATE_STATUS)."
        echo "Response: $CREATE_BODY"
        exit 1
    fi
fi

# 4b. Handle uncommitted changes in Dataform
if [[ "$DATAFORM_HAS_CHANGES" == "true" ]]; then
    echo "💾 Uncommitted changes detected in Dataform. Committing them first..."
    
    # If we only have changes in Dataform (and none in Cursor), it's safe to commit them
    read -p "Do you want to add a custom commit message for Dataform changes? (y/N): " df_custom_msg_choice
    
    if [[ "$df_custom_msg_choice" =~ ^[Yy]$ ]]; then
        read -p "Enter your Dataform commit message: " df_commit_msg
        if [[ -z "$df_commit_msg" ]]; then
            echo "⚠️ Empty message provided. Falling back to default."
            df_commit_msg="chore: auto-sync from cloud IDE"
        fi
    else
        df_commit_msg="chore: auto-sync from cloud IDE"
    fi
    
    COMMIT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"author\": {\"name\": \"Jose Tejada\", \"emailAddress\": \"jose.tejada@soundcloud.com\"}, \"commitMessage\": \"$df_commit_msg\"}" \
      "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:commit")
      
    COMMIT_STATUS=$(echo "$COMMIT_RESPONSE" | tail -n1)
    
        if [ "$COMMIT_STATUS" -eq 200 ]; then
            echo "✅ Successfully committed changes in Dataform."
            
            # Since we might have pushed local changes to GitHub earlier in the script,
            # we MUST pull them into Dataform before we can push Dataform's changes out.
            echo "🔄 Pulling GitHub changes into Dataform before pushing..."
            PULL_MERGE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Authorization: Bearer $AUTH_TOKEN" \
              -H "Content-Type: application/json" \
              -d "{\"remoteBranch\": \"${CURRENT_BRANCH}\", \"author\": {\"name\": \"${GIT_USER_NAME}\", \"emailAddress\": \"${GIT_USER_EMAIL}\"}}" \
              "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:pull")
            
            PULL_MERGE_STATUS=$(echo "$PULL_MERGE_RESPONSE" | tail -n1)
            PULL_MERGE_BODY=$(echo "$PULL_MERGE_RESPONSE" | sed '$d')

            # Check if the pull resulted in a merge conflict
            if echo "$PULL_MERGE_BODY" | grep -q "Merge conflict"; then
                echo "❌ ERROR: Merge conflict detected in Dataform!"
                echo "You made changes to the same file in both Cursor and Dataform."
                echo "The conflict markers (<<<<<<< HEAD) have been written to your Dataform workspace."
                echo "👉 Please go to Dataform, resolve the conflicts manually, and commit them."
                echo "Link: https://console.cloud.google.com/bigquery/dataform/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}?project=${DATAFORM_PROJECT}"
                exit 1
            fi
            
            # If the pull was successful, we need to commit the merge before pushing
            # Dataform requires a merge commit if the pull brought in changes that needed merging
            echo "💾 Committing the merge in Dataform..."
            MERGE_COMMIT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Authorization: Bearer $AUTH_TOKEN" \
              -H "Content-Type: application/json" \
              -d "{\"author\": {\"name\": \"${GIT_USER_NAME}\", \"emailAddress\": \"${GIT_USER_EMAIL}\"}, \"commitMessage\": \"Merge remote-tracking branch '${CURRENT_BRANCH}'\"}" \
              "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:commit")
            
            echo "🚀 Pushing Dataform changes to GitHub..."
        PUSH_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          -H "Authorization: Bearer $AUTH_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"remoteBranch\": \"${CURRENT_BRANCH}\"}" \
          "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:push")
          
        PUSH_STATUS=$(echo "$PUSH_RESPONSE" | tail -n1)
        
        if [ "$PUSH_STATUS" -eq 200 ] || [ "$PUSH_STATUS" -eq 204 ]; then
            echo "✅ Successfully pushed Dataform changes to remote."
            echo "☁️ Pulling new Dataform changes to local Cursor..."
            git pull --rebase origin "$CURRENT_BRANCH"
        else
            echo "⚠️ Warning: Failed to push Dataform changes (HTTP $PUSH_STATUS)."
            echo "Response: $(echo "$PUSH_RESPONSE" | sed '$d')"
        fi
    else
        echo "❌ ERROR: Failed to commit Dataform changes."
        echo "Response: $(echo "$COMMIT_RESPONSE" | sed '$d')"
    fi
else
    # 4c. Sync the workspace with the remote branch (Pulling Cursor changes UP to Dataform)
    echo "🔄 Pulling latest commits into Dataform workspace..."
    
    # We add a small sleep here because sometimes the Dataform API takes a second to register
    # that the workspace was just reset and is now clean.
    sleep 2
    
    PULL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"remoteBranch\": \"${CURRENT_BRANCH}\", \"author\": {\"name\": \"${GIT_USER_NAME}\", \"emailAddress\": \"${GIT_USER_EMAIL}\"}}" \
      "https://dataform.googleapis.com/v1beta1/projects/${DATAFORM_PROJECT}/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}:pull")

    PULL_STATUS=$(echo "$PULL_RESPONSE" | tail -n1)
    PULL_BODY=$(echo "$PULL_RESPONSE" | sed '$d')

    if [ "$PULL_STATUS" -eq 200 ] || [ "$PULL_STATUS" -eq 204 ]; then
        echo "🎉 SUCCESS: Dataform workspace '${DATAFORM_WORKSPACE}' successfully synced with branch '${CURRENT_BRANCH}'!"
        echo "👉 Link: https://console.cloud.google.com/bigquery/dataform/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}?project=${DATAFORM_PROJECT}"
    elif echo "$PULL_BODY" | grep -q "Merge conflict"; then
        echo "❌ ERROR: Merge conflict detected in Dataform!"
        echo "You made changes to the same file in both Cursor and Dataform."
        echo "The conflict markers (<<<<<<< HEAD) have been written to your Dataform workspace."
        echo "👉 Please go to Dataform, resolve the conflicts manually, and commit them."
        echo "Link: https://console.cloud.google.com/bigquery/dataform/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPOSITORY}/workspaces/${DATAFORM_WORKSPACE}?project=${DATAFORM_PROJECT}"
        exit 1
    else
        echo "⚠️ Warning: Dataform sync failed (HTTP $PULL_STATUS)."
        echo "Response: $PULL_BODY"
    fi
fi
