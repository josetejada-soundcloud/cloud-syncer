# Cloud Syncer ☁️🔄

A "One-Click" synchronization tool that bridges the gap between local development (Cursor) and cloud-based IDEs (Dataform, Looker).

Instead of manually committing, pushing, and pulling across different browser tabs to keep environments mirrored, a single keyboard shortcut automatically handles the two-way Git sync and triggers the necessary API calls to refresh the cloud environments.

## Features
* **One-Click Sync:** Press `Cmd + Shift + S` to instantly sync your local changes to the cloud.
* **Two-Way Sync:** Automatically pulls cloud changes down to your local machine.
* **Auto-Workspace Creation:** If a Dataform workspace doesn't exist for your branch, it creates it automatically.
* **Conflict Protection:** Detects if you've edited the same file in both environments and provides an interactive menu to safely discard changes without causing massive merge conflicts.
* **Custom Commits:** Prompts you for clean commit messages to keep your Git history readable.

## Installation

Run the following command in your terminal to install the script and configure Cursor:

```bash
git clone https://github.com/josetejada-soundcloud/cloud-syncer.git
cd cloud-syncer
./install.sh
```

## Usage

1. Open any file in a Git repository inside Cursor.
2. Press **`Cmd + Shift + S`**.
3. The script will automatically detect your current branch, sync it with GitHub, and trigger the Dataform/Looker APIs to refresh your cloud workspace.

## Prerequisites
* You must have the Google Cloud CLI (`gcloud`) installed and authenticated (`gcloud auth login`).
* You must have access to the relevant Dataform/Looker projects.

## Configuration

By default, the script looks for environment variables to know which GCP project and Dataform repository to sync with. 

You can set these in your `~/.bashrc` or `~/.zshrc`:
```bash
export DATAFORM_PROJECT="your-gcp-project-id"
export DATAFORM_LOCATION="europe-west1"
export DATAFORM_REPOSITORY="your-dataform-repo-name"
```
*(Alternatively, you can open `~/.cursor/scripts/cloud-sync.sh` after installation and hardcode your team's specific variables directly at the top of the file).*

## Next Steps & Roadmap 🚀
While the current version is highly optimized for **Dataform** and **Cursor**, the architecture is designed to be easily extensible:
* **Integrate with Looker & Deepnote:** By swapping out the GCP API hooks for Looker's `sync_project_with_git` or Deepnote's GitHub integration endpoints, this tool can seamlessly sync across the entire data stack.
* **Chrome Extension:** Build a lightweight Chrome extension so you can trigger the two-way sync directly from your browser while looking at the cloud IDE, without needing to switch back to Cursor.