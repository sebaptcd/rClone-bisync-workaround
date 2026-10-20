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

- Linux with Bash, `cron`, `ping` (`iputils-ping`) and `notify-send` (`libnotify-bin`). The script needs a desktop session for notifications and can exit if one is unavailable.
- `rclone` v1.66+ (v1.71+ recommended) in cron's `PATH`, with remotes configured (`rclone config`).
- Run as your normal user, not as root.

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

The script syncs exactly four pairs: `Personal`, `PersonalPb`, `Dev` and `WORKSTATION`. The names are hard-coded; if you have fewer or more, edit the matching variables and the `rclone sync`/`bisync` calls in both the boot and cycle sections of `Syncing.sh`.

### 1. Place the files

The full layout expected by `Syncing.sh`:

```text
/home/{user}/rCloneSync/
├── rClone-bisync-workaround/
│   └── Syncing.sh
├── 0. Private/
│   └── rClone-bisync-workaround/
│       └── var.sh
├── Cloud/
│   ├── {Provider 1}/
│   ├── {Provider 2}/
│   ├── {Provider 3}/
│   └── {Provider 4}/
├── Backup/
│   ├── {Provider 1}/
│   └── rClone bin/
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

`Syncing.sh` sources `../0. Private/rClone-bisync-workaround/var.sh` relative to itself. If you use another layout, change that `source` line.

### 2. Create `var.sh`

Create `/home/{user}/rCloneSync/0. Private/rClone-bisync-workaround/var.sh`:

```bash
#!/bin/bash

# Locks, logs and machine ID. Must not contain spaces.
Setups='/home/{user}/rCloneSync/Setups'

# Recycle bin parent: "$recycle_bin_root/rClone bin".
recycle_bin_root='/home/{user}/rCloneSync/Backup'

# Personal
Personal_remote='{Provider 1}:'
Personal_local='/home/{user}/rCloneSync/Cloud/{Provider 1}'
Personal_local_backup='/home/{user}/rCloneSync/Backup/{Provider 1}'

# Personal/Public
PersonalPb_remote='{Provider 2}:Drive'
PersonalPb_local='/home/{user}/rCloneSync/Cloud/{Provider 2}'

# Dev
Dev_remote='{Provider 3}:Drive'
Dev_local='/home/{user}/rCloneSync/Cloud/{Provider 3}'

# WORKSTATION
WORKSTATION_remote='{Provider 4}:@WORKSTATION'
WORKSTATION_local='/home/{user}/rCloneSync/Cloud/{Provider 4}'

# Shared by every machine. "Remote:" for root, "Remote:path/" for a subfolder.
SyncControl_root='{Provider of your choice}:'
```

Replace every `{...}` placeholder. Remote names must match `rclone config`: `Name:` for the remote root, `Name:path` for a folder.

- `Setups` must not contain spaces: `machineID.txt` is read unquoted from it.
- `SyncControl_root` must not contain spaces, must point to the same location on every machine, and must end with `/` when it is a subfolder.
- Only these variables are read. `Err` and `PersonalPb_root_remote` from older configurations are ignored.

### 3. Create the folders and machine ID

```bash
source "/home/{user}/rCloneSync/0. Private/rClone-bisync-workaround/var.sh"

mkdir -p "$Personal_local" "$PersonalPb_local" "$Dev_local" "$WORKSTATION_local" \
         "$Personal_local_backup" "$recycle_bin_root/rClone bin"

mkdir -p "$Setups/rClone-bisync-workaround/Locks" \
         "$Setups/rClone-bisync-workaround/Logs/Boot/Canceled" \
         "$Setups/rClone-bisync-workaround/Logs/Sync/Canceled"

printf '%s\n' 'DESKTOP-1' > "$Setups/rClone-bisync-workaround/machineID.txt"
chmod 600 "$Setups/rClone-bisync-workaround/machineID.txt"
```

`machineID.txt` must be unique per computer and contain only letters, digits, `-` and `_` (no spaces). The script exits if the file is missing.

The remote base path for each pair must exist as well; `bisync` aborts if it is missing. Create missing folders with `rclone mkdir '{Provider}:path'` (a remote root such as `{Provider}:` normally already exists).

### 4. Rebuild the bisync baselines once

Run these commands once before starting the script. Without a baseline, normal `bisync` runs abort and ask for `--resync`.

```bash
source "/home/{user}/rCloneSync/0. Private/rClone-bisync-workaround/var.sh"

FLAGS=(--transfers 64 --checkers 48 --create-empty-src-dirs --local-links
       --fix-case --force --recover --resilient --max-lock 600)

rclone bisync --resync "${FLAGS[@]}" "$Personal_local"     "$Personal_remote"
rclone bisync --resync "${FLAGS[@]}" "$PersonalPb_remote"  "$PersonalPb_local"
rclone bisync --resync "${FLAGS[@]}" "$Dev_remote"         "$Dev_local"
rclone bisync --resync "${FLAGS[@]}" "$WORKSTATION_remote" "$WORKSTATION_local"
```

`--resync` merges both sides; it is not a one-way mirror. On a conflict, the first path wins (local for `Personal`, remote for the other three). If both sides already contain data, run the commands with `--dry-run` first, then repeat without it.

For `Personal`, run this before the first boot: the boot sync copies the remote to the local folder and would otherwise move local-only files to the recycle bin.

### 5. Make the script executable

```bash
chmod +x "/home/{user}/rCloneSync/rClone-bisync-workaround/Syncing.sh"
```

### 6. Start it at boot

```bash
crontab -e
```

Add:

```cron
PATH=/usr/local/bin:/usr/bin:/bin
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

@reboot sleep 30 && "/home/{user}/rCloneSync/rClone-bisync-workaround/Syncing.sh" >> "/home/{user}/rCloneSync/Setups/rClone-bisync-workaround/cron.log" 2>&1
```

Replace both `1000`s with your UID (`id -u`), and make sure `PATH` contains the directory from `command -v rclone`. Increase `sleep 30` if your desktop session starts slowly. The two session variables are required for `notify-send`; without them the script can exit.

### 7. Test it

```bash
bash -n "/home/{user}/rCloneSync/rClone-bisync-workaround/Syncing.sh"
"/home/{user}/rCloneSync/rClone-bisync-workaround/Syncing.sh"
```

The first start runs the boot sync, waits 5 minutes and begins the regular cycles. Completed runs are in `$Setups/rClone-bisync-workaround/Logs/`; early startup errors are in `$Setups/rClone-bisync-workaround/cron.log`.

## Troubleshooting

- **Script exits immediately:** verify that `var.sh` exists at the path in `source`, all paths in it exist, `machineID.txt` exists, and `rclone` is on the cron `PATH`.
- **`Bisync aborted. Must run --resync`:** run the resync command for that pair from step 4. This can also happen after an unrecoverable bisync error.
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
- sends a Termux notification when a cycle fails (`termux-notification`, falling back to `notify-send`). Notifications run in the background, so an unavailable or stalled Termux:API service cannot block the countdown or the next cycle;
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
