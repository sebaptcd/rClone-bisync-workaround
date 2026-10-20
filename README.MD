# rClone bisync automation

**Why?**
rClone's `bisync` is no longer in beta. This repository still exists because it automates the parts that `bisync` does not handle by itself: starting at boot, repeating sync cycles, coordinating multiple machines, keeping logs, and sending desktop notifications.

**What?**
A Bash wrapper around rClone, started once at boot by a user crontab. It performs a boot sync, then repeats a sync cycle forever. A remote lock stops two machines from syncing at the same time.

**How?**
The heavy lifting is done by `rclone bisync` (bidirectional) and `rclone sync` (the local backup/recycle-bin step). The script coordinates the runs, the cross-machine lock, and the logs.

**Contribute!**
If you have any suggestions or improvements, please open a pull request.

## Tested OS

- Debian 13 Trixie (GNOME 48)
- Debian 12 Bookworm (GNOME 43.9)

## Requirements

- Linux with Bash and a running `cron` service (install it with `sudo apt install cron` if needed).
- `rclone` installed and available on the `PATH` used by cron, with your remotes configured (`rclone config`).
  - Use rclone **v1.71 or newer** for stable bisync. The script's `--resilient` and `--recover` flags require at least v1.66.
  - Review rclone's [bisync limitations](https://rclone.org/bisync/#limitations) before using it with important data.
- `notify-send` from `libnotify-bin` and a running desktop/DBus session:

  ```bash
  sudo apt install libnotify-bin
  ```

  The script runs with `set -e` and calls `notify-send` directly, so if notifications fail, the script may exit. A desktop session is therefore effectively required unless you adapt those calls.
- `ping` (`iputils-ping`) for the internet check. The script pings `8.8.8.8`; on networks that block ICMP, adjust the check.
- Run the script as your normal user, not as root. It uses your rclone configuration and your desktop session.

## How it works

### Boot sync (once per boot)

1. Cron starts the script 30 seconds after boot. The script creates `Boot-Sync.lock` and waits another 30 seconds.
2. It runs `rclone selfupdate --check`. If a newer rclone version is reported, it waits 5 minutes so you can update.
3. It waits for the cross-machine lock (see below).
4. **Personal remote:** `rclone sync` copies the remote to the local folder. It uses `--update`, so newer local files are kept. Local files that would be deleted are moved to the recycle bin. Then `rclone bisync --resync` runs between the local folder and the remote.
5. **Other remotes:** normal `rclone bisync`.
6. It removes the cross-machine lock, moves `Boot-Sync.lock` to `Logs/Boot/`, creates `Boot-Ran.lock`, and waits 5 minutes.

The `--resync` for the Personal remote is intentional and runs on every boot. Combined with the `rclone sync` from the remote to the local folder, it makes the boot sync refresh the local copy from the remote. The trade-off is described in [Known issues](#known-issues).

### Sync cycle (repeats forever)

1. It waits for the cross-machine lock, then marks this machine as active.
2. **Personal remote:** `rclone sync` copies the local folder to `Personal_local_backup`.
3. All remotes: `rclone bisync`.
4. It removes the cross-machine lock, moves `Sync.lock` to `Logs/Sync/`, and waits 5 minutes.
5. It repeats from step 1.

### Cross-machine lock

The lock is stored on the `SyncControl_root` remote at:

```text
syncControl/syncTime.lock
```

It contains `<unix timestamp> <machineID>`. While syncing, the active machine rewrites the timestamp every 15 seconds. Other machines consider the lock active if the timestamp is less than 120 seconds old. Older locks are treated as stale and removed. This is what allows the script to run on several computers without syncing them at the same time.

`rclone bisync` also has its own `--max-lock 600` setting; that is separate from this custom lock.

### Logs and recycle bin

- `Logs/Boot/` — completed boot syncs.
- `Logs/Sync/` — completed regular cycles.
- `Logs/Boot/Canceled/` and `Logs/Sync/Canceled/` — runs that were interrupted or detected as overlapping.
- While a run is in progress, output is appended to the `Boot-Sync.lock` or `Sync.lock` file. When the run finishes, that file is moved into the matching log folder.
- The recycle bin is `$recycle_bin_root/rClone bin/<timestamp>`. `rclone sync` uses it as `--backup-dir`, so replaced or deleted local files are moved there instead of being lost.

## Install

### 1. Place the files

The default layout expected by `Syncing.sh` is:

```text
/home/{user}/Desktop/rCloneSync/
├── rClone-bisync-workaround/
│   └── Syncing.sh
├── 0. Private/
│   └── rClone-bisync-workaround/
│       └── var.sh
├── Cloud/
│   ├── {Provider 1}/
│   └── {Provider 2}/
├── {Provider 3}/
│   └── Cloud/
├── {Provider 4}/
│   └── Cloud/
├── Backup/
│   └── rClone Backup/
│       └── {Provider 1}/
└── Setups/
    └── rClone-bisync-workaround/
        ├── machineID.txt
        ├── Locks/
        └── Logs/
            ├── Boot/
            │   └── Canceled/
            └── Sync/
                └── Canceled/
```

`Syncing.sh` sources `var.sh` from a path relative to its own directory:

```bash
source "$script_dir/../0. Private/rClone-bisync-workaround/var.sh"
```

If you put the files somewhere else, update that line in `Syncing.sh`.

### 2. Create `var.sh`

Create `/home/{user}/Desktop/rCloneSync/0. Private/rClone-bisync-workaround/var.sh` with your paths:

```bash
#!/bin/bash

# Parent folder for this script's state (locks, logs, machine ID).
# Keep this path free of spaces: the script reads machineID.txt without quotes.
Setups='/home/{user}/Desktop/rCloneSync/Setups'

# Root of the recycle bin. The script uses "$recycle_bin_root/rClone bin".
recycle_bin_root='/home/{user}/Desktop/rCloneSync/Backup'

# Drive 1: Personal (boot sync uses rclone sync + bisync --resync)
Personal_remote='{Provider 1}:'
Personal_local='/home/{user}/Desktop/rCloneSync/Cloud/{Provider 1}'
Personal_local_backup='/home/{user}/Desktop/rCloneSync/Backup/rClone Backup/{Provider 1}'

# Drive 2
PersonalPb_remote='{Provider 2}:Drive'
PersonalPb_local='/home/{user}/Desktop/rCloneSync/Cloud/{Provider 2}'

# Drive 3
Dev_remote='{Provider 3}:Drive'
Dev_local='/home/{user}/Desktop/rCloneSync/{Provider 3}/Cloud'

# Drive 4
WORKSTATION_remote='{Provider 4}:@WORKSTATION'
WORKSTATION_local='/home/{user}/Desktop/rCloneSync/{Provider 4}/Cloud'

# Remote used for the cross-machine lock.
# Use "Remote:" for the remote root, or "Remote:path/" for a subfolder.
SyncControl_root='{Provider of your choice}:'
```

Notes:

- Replace every `{...}` placeholder.
- Remote names must match the names in `rclone config`. A remote root is written as `Name:`; a folder inside it is `Name:path`.
- The script reads exactly these variables. `Err` and `PersonalPb_root_remote` from older configurations are not used.
- Keep `Setups` free of spaces. The script uses it unquoted when reading `machineID.txt`.
- `SyncControl_root` must be reachable from every machine that runs the script. If you use a subfolder, end it with a slash (for example `'Dev:Apps/'`).

### 3. Configure rclone and create the local folders

Configure the remotes:

```bash
rclone config
```

Check each one:

```bash
rclone lsd "{Provider 1}:"
```

Create the local folders from `var.sh`:

```bash
mkdir -p \
  "/home/{user}/Desktop/rCloneSync/Cloud/{Provider 1}" \
  "/home/{user}/Desktop/rCloneSync/Cloud/{Provider 2}" \
  "/home/{user}/Desktop/rCloneSync/{Provider 3}/Cloud" \
  "/home/{user}/Desktop/rCloneSync/{Provider 4}/Cloud" \
  "/home/{user}/Desktop/rCloneSync/Backup/rClone Backup/{Provider 1}"
```

`Dev_local` and `WORKSTATION_local` are not under `Cloud/` in the example, which is why they are listed separately.

### 4. Create the state folders and machine ID

```bash
mkdir -p \
  "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/Locks" \
  "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/Logs/Boot/Canceled" \
  "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/Logs/Sync/Canceled"

printf '%s\n' 'DESKTOP-1' > \
  "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/machineID.txt"
chmod 600 \
  "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/machineID.txt"
```

`machineID.txt` must be unique per computer. Use letters, numbers, `-`, and `_` only (no spaces). The script reads it from `$Setups/rClone-bisync-workaround/machineID.txt`; if the file is missing, the script exits.

### 5. Initialize every bisync pair once

Do not start the script for the first time before completing this step.

`rclone bisync` needs a baseline listing for each pair. Without it, the first run aborts with:

```text
Bisync critical error: cannot find prior Path1 or Path2 listings ...
Bisync aborted. Must run --resync to recover.
```

Run `--resync` once for each pair, using the same sync-related flags and argument order as the script. Review it with `--dry-run` first if both sides already contain data.

```bash
# Personal: local is Path1, remote is Path2 (same order as Syncing.sh)
rclone bisync --resync \
  --transfers 64 --checkers 48 --create-empty-src-dirs --local-links \
  --fix-case --force --recover --resilient --max-lock 600 \
  "/home/{user}/Desktop/rCloneSync/Cloud/{Provider 1}" \
  "{Provider 1}:"

# Personal/Public: remote is Path1, local is Path2
rclone bisync --resync \
  --transfers 64 --checkers 48 --create-empty-src-dirs --local-links \
  --fix-case --force --recover --resilient --max-lock 600 \
  "{Provider 2}:Drive" \
  "/home/{user}/Desktop/rCloneSync/Cloud/{Provider 2}"

# Dev
rclone bisync --resync \
  --transfers 64 --checkers 48 --create-empty-src-dirs --local-links \
  --fix-case --force --recover --resilient --max-lock 600 \
  "{Provider 3}:Drive" \
  "/home/{user}/Desktop/rCloneSync/{Provider 3}/Cloud"

# WORKSTATION
rclone bisync --resync \
  --transfers 64 --checkers 48 --create-empty-src-dirs --local-links \
  --fix-case --force --recover --resilient --max-lock 600 \
  "{Provider 4}:@WORKSTATION" \
  "/home/{user}/Desktop/rCloneSync/{Provider 4}/Cloud"
```

`--resync` is **not** a one-way mirror. It rebuilds the bisync listings and merges both sides; on conflicts, Path1 wins. Running it for Personal before the first boot is important: the boot sync first runs `rclone sync` from the remote to the local folder, which would move local-only files to the recycle bin.

### 6. Make the script executable

```bash
chmod +x "/home/{user}/Desktop/rCloneSync/rClone-bisync-workaround/Syncing.sh"
```

`var.sh` only needs to be readable; it does not need execute permission.

### 7. Add the crontab entry

Make sure cron is running:

```bash
sudo systemctl enable --now cron
```

Open your user crontab:

```bash
crontab -e
```

Add:

```cron
# rClone bisync automation
PATH=/usr/local/bin:/usr/bin:/bin
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

@reboot sleep 30 && "/home/{user}/Desktop/rCloneSync/rClone-bisync-workaround/Syncing.sh" >> "/home/{user}/Desktop/rCloneSync/Setups/rClone-bisync-workaround/cron.log" 2>&1
```

Replace `1000` with your user ID (`id -u`). Check that `PATH` contains the directory reported by `command -v rclone`. If your desktop session uses a different display, edit the `export DISPLAY=:0` line in `Syncing.sh`.

Notes:

- `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` let `notify-send` reach your desktop session from cron. If they are wrong, notifications fail and the script may exit.
- Increase the first `sleep 30` if your desktop session takes longer to start.
- `@reboot` starts the script once. The script then loops forever. If it exits, cron will not restart it until the next boot; start it manually or use a service manager if you need automatic restarts.
- The `cron.log` redirection captures output that is not written to the boot/sync lock files, including early startup errors.

### 8. Test it

Syntax-check the scripts first:

```bash
bash -n "/home/{user}/Desktop/rCloneSync/rClone-bisync-workaround/Syncing.sh"
bash -n "/home/{user}/Desktop/rCloneSync/0. Private/rClone-bisync-workaround/var.sh"
```

Then start it in the foreground and watch the output:

```bash
"/home/{user}/Desktop/rCloneSync/rClone-bisync-workaround/Syncing.sh"
```

You can stop it with `Ctrl+C`. If a bisync run was interrupted, the next run uses `--recover`; if rclone still asks for a resync, run the matching command from step 5. A leftover lock file is detected on the next start and moved to `Canceled` after a 5-minute wait. Check `Logs/Boot/` and `Logs/Sync/` for completed runs, and `cron.log` for early errors.

## Troubleshooting

- **Script exits immediately:** verify that `var.sh` exists at the path in `source`, all paths in it exist, `machineID.txt` exists, and `rclone` is on the cron `PATH`.
- **`Bisync aborted. Must run --resync`:** run the resync command for that pair from step 5. This can also happen after an unrecoverable bisync error.
- **No notifications or the script exits when notifying:** test `notify-send` as the same user, check `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`, and make sure `libnotify-bin` is installed.
- **Nothing runs after reboot:** check `systemctl status cron`, the `cron.log` file, and that the script is executable.
- **Two machines wait on each other:** the custom lock is stale after 120 seconds. Check the remote `syncControl/syncTime.lock` and remove it manually if needed. rclone's own lock (`--max-lock 600`) is separate.
- **Every boot waits 5 minutes for an update:** the update check uses `rclone selfupdate --check`. Some rclone builds (for example distro packages or Termux) do not provide `selfupdate`. Update rclone or comment out that block in `Syncing.sh`.

## Known issues

These affect the **Personal** remote only. It is the only pair that runs `rclone sync` from the remote to the local folder at boot; the other pairs use bisync only.

### 1. Files deleted locally just before shutdown come back on the next boot

If you delete files locally during the 5-minute cooldown and shut down before the next cycle, the boot `rclone sync` sees the files on the remote and restores them locally.

**Workarounds:**

1. After the boot sync completes, delete the files locally again and let the next cycle propagate the deletion to the server.
2. Delete the files directly on the server; the next boot sync/bisync will propagate the deletion locally.

### 2. New local files can be removed on the next boot if they were never synced

If you create files locally and shut down before any sync cycle runs, the boot `rclone sync` from remote to local treats them as extra local files and moves them to the recycle bin.

**Workaround:** keep the computer on until at least one sync cycle completes after creating new files. Check `Logs/Sync/` to confirm. The files are moved to the recycle bin, not permanently deleted, so they can be restored from `$recycle_bin_root/rClone bin/<timestamp>`.

### Resolved issues

The following were fixed by bisync and the cross-machine lock in v3.0.0.0 mk1:

- New files created on the server after boot being deleted.
- Renames on the server after boot not taking effect.
- Files created in the middle of a sync cycle being deleted.
- Collisions when two computers are on at the same time.

## Android / Termux (`MobileSync.sh`)

`MobileSync.sh` is a separate wrapper for running the same idea on Android via Termux. It does not use cron; start it manually in a Termux session. If you automate it with Termux:Boot, create `machineID.txt` and run the first `--resync` beforehand so startup does not need interactive input.

Requirements:

```bash
pkg install bash rclone
termux-setup-storage

# Optional: Android notifications (requires the Termux:API app)
pkg install termux-api
```

Configure your remotes with `rclone config`. Then edit the configuration block at the top of `MobileSync.sh`:

- `SYNC_LOCK_REMOTE` and `LOG_REMOTE_PATH` (currently under `Dev:syncControl/`)
- `REMOTE_NAMES`, `LOCAL_PATHS`, and `REMOTE_LABELS`
- Optionally `BISYNC_FLAGS`, `LOCK_TIMEOUT`, and `SYNC_INTERVAL`

Create `machineID.txt` in the directory you run the script from, or let the script prompt for it on first run. The same naming rule applies: letters, numbers, `-`, and `_` only. Then run:

```bash
cd /path/to/rClone-bisync-workaround
bash MobileSync.sh
```

On first run, choose `--resync` for each remote (`A` = all, `N` = none, `S` = select individually). `--resync` rebuilds the bisync state and is not a one-way mirror.

`MobileSync.sh`:

- uses the same lock mechanism as `Syncing.sh` (set `SYNC_LOCK_REMOTE` to `<SyncControl_root>syncControl/syncTime.lock`);
- syncs each configured pair with `--recover --resilient`;
- streams rclone `ERROR`, `CRITICAL` and `NOTICE` lines to the terminal while the full output is still written to the log;
- checks the exit code of every pair: `0` is success, `1` is a non-critical failure, `2` is a command/flag error, and `7` is a critical abort that requires `--resync`;
- prints the last error and an authentication hint when a login has expired, then continues with the next remote;
- only reports `Cycle completed` when every pair succeeded. Otherwise it prints a per-remote failure summary and tries again next cycle;
- uploads a live log and a final log to `Dev:syncControl/Logs/<machineID>/`;
- deletes remote logs older than 24 hours. If the upload fails, it keeps the local log and prints its path;
- sends a Termux notification when a cycle fails (`termux-notification`, falling back to `notify-send`);
- waits 5 minutes between cycles. Press `S` to skip the wait, or `P` to pause/resume the countdown display;
- if the `Dev:` lock remote cannot be reached, shows the error and skips that cycle instead of syncing without the cross-machine lock. It retries on the next cycle;
- uses `termux-wake-lock` when available so Android does not suspend the process.

### Authentication errors

rclone's saved logins can expire or be revoked. The script now shows these failures instead of reporting a successful cycle. Common examples:

- `expired_access_token` (Dropbox)
- `InvalidAuthenticationToken: AuthenticationException` (OneDrive / Microsoft)
- `invalid_grant` or `Token has been expired or revoked` (Google Drive)

Reconnect the remote shown in the error message:

```bash
rclone config reconnect Dropbox:
rclone config reconnect WORKSTATION:
```

Replace the name with the remote from the error (the script prints the exact command). After reconnecting, start `MobileSync.sh` again and choose `--resync` for the affected remote when the log says `Bisync aborted. Must run --resync to recover.`. A missing login does not stop the other remotes or the loop; the failed pair is simply retried next cycle.

## Versioning

This repository follows the [iVer](https://github.com/frontfacer/iVer) versioning format. See [RELEASE.md](RELEASE.md) for release notes.

## Contact

If you need help setting things up, reach out to [open@sebastian.ghiveci.com](mailto:open@sebastian.ghiveci.com).

---

© 2024-2026 | Sebastian Ghiveci<br>
sebastian.ghiveci.com
