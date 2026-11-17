# Unraid media folder consolidation

Jellyfin on an Unraid array can spread one movie or show across several disks: the video lands on one disk while trickplay images, subtitles, artwork and NFO files stay on another. This script finds the disk holding the video for each movie and show, treats it as the master, and copies everything from the other disks onto it with `rsync`. Folders are merged, never replaced.

It ships as a dry run. The first pass over a real library moves nothing, writes a log, and lists every folder it could not decide.

## What it does

For each folder one level below a configured root (one folder per movie, one per show):

1. Look for a file with a configured video extension on each disk in `DISKS`.
2. One disk holds video: that disk is the master, and every other disk's copy of the folder is copied onto it.
3. No disk holds video: the folder is skipped and listed in the report.
4. Two or more disks hold video: the folder is merged unless any folder directly below it, a season in the usual layout, holds video on two disks. The merge target is the disk with the most video files, and ties go to the earlier entry in `DISKS`. If a season is split across disks, the folder is skipped and the conflicting seasons are listed at the end of the run.

Copies use `rsync --ignore-existing`, so nothing already on the master is overwritten, plus `--remove-source-files`, so a source file is deleted only after its copy is complete. Directories left empty are pruned.

## Requirements

- Unraid, run as `root`: the script reads and writes `/mnt/disk*`.
- bash 4 or newer, GNU `find` for `-printf`, `rsync`, and coreutils for `paste`, `sort`, `tee` and `sed`.
- Array disks at `/mnt/disk1` and up, or your own list in `DISKS`. Never point it at `/mnt/user`: the FUSE view hides which disk holds a file, so a move can target a file's own location.

## Install

Through Unraid's User Scripts plugin:

1. Open the User Scripts plugin and choose ADD NEW SCRIPT.
2. Paste the contents of `media-folder-consolidation.sh`.
3. Edit the constants below, save, then Run Script.

Any other host works if the paths in `DISKS` and `FOLDERS` exist: `bash media-folder-consolidation.sh`.

## Configure

Every setting is a constant at the top of the script. There are no flags and no environment variables, so the file you read is the file that runs.

| Constant | Meaning |
| --- | --- |
| `DRY_RUN` | `1` (default) prints what would happen, `0` moves files. Any other value aborts before scanning. |
| `DISKS` | Disks to scan, as `/mnt/diskN`. |
| `FOLDERS` | Media roots relative to each disk. One level below a root is one movie or show. |
| `VIDEO_EXTS` | Lowercase extensions without dots, matched case-insensitively. A file with one of these marks its disk as holding the video. |
| `LOG_DIR` | Where each run writes its log. Keep it outside the scanned roots: the log is the only file a dry run creates. |

```bash
DRY_RUN=1
DISKS=(/mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 /mnt/disk5 /mnt/disk6)
FOLDERS=(
    "Data/Movies"
    "Data/TV_Shows/Live Action"
    # ... one entry per media root
)
VIDEO_EXTS=(mkv mp4 m4v avi mov wmv flv webm mpg mpeg ts m2ts mts vob ogv ogm divx 3gp)
LOG_DIR=/mnt/user/tmp
```

## Run it

1. Leave `DRY_RUN=1` and run. The header names the log file, every `rsync` call reports `(DRY RUN)`, and no media file is touched.
2. Read the report at the end of the log, also printed in the console. The report says not to run live while it lists folders: resolve each one, then repeat the dry run.
3. When the run ends with `No issues found - safe to set DRY_RUN=0 and run live.`, set `DRY_RUN=0` and run once more.
4. After a live run, check the output for `FAILED:`. A failed transfer is counted and the run exits non-zero so a scheduler notices; files not yet copied stay on the source and are retried on the next run.

A file present on both the master and a source disk is neither copied nor deleted. That protects the master's copy and leaves the duplicate on the source, so a folder can stay on two disks with the shared filenames left behind. The log shows such a source left in place.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Dry run found no issues, or the live run had no failed folder. |
| `1` | Dry run found issues, or at least one folder failed to move during a live run. |
| `2` | Refused to start: `DRY_RUN` is not `0` or `1`, `VIDEO_EXTS` is empty, or the log file cannot be written. |

## Tests

```bash
bash tests/run-tests.sh
```

A plain bash runner with no dependencies. Each case builds fake disks in a temporary directory, copies the script with `/mnt/disk` rewritten into that tree, and asserts behaviour rather than internals: a folder consolidates onto the disk holding the video, a folder on two disks is skipped and named, a split season is refused, a dry run moves nothing and writes exactly one log, a failed `rsync` is not reported as success. `/mnt` is never touched, and the harness fails loudly if the rewrite stops applying.

## Limitations

- No free-space check. A live run can fill a disk; `rsync` then fails, the folder is reported `FAILED:`, and the partial copy stays on the master.
- Name matching is case-sensitive, so `Foo (2001)` and `foo (2001)` are two shows and never merge.
- Symlinked directories are ignored: the scan matches real directories only.
- Season detection reads the first path component below a show. Video placed directly in the show folder is reported as `(top level)`, and seasons nested deeper (`Season 01/Disc 1`) still resolve to `Season 01`.
- Copying between array disks is a copy followed by a delete, not a rename. An interrupted run leaves both copies.
- Only extensions in `VIDEO_EXTS` count as video. A show in another container is skipped and named in the report.

## Tested on

A 42 TiB Jellyfin library: 54,188 files across six disks and 3,066 movie and show folders. A dry run over that tree left every file and directory in place: 2,871 folders had one master disk, 58 merged across disks, and 137 were refused because a season sits on two disks. Its decisions matched an independent re-implementation, with the only differences explained by folders deleted between the two snapshots. A live pass on a copy of the tree then moved 1,720 folder merges with no file lost.

## Contributing

Issues and pull requests are welcome. Run `bash tests/run-tests.sh` and `bash -n media-folder-consolidation.sh` before sending a change, and add a case to `tests/run-tests.sh` for any behaviour you alter.

## License

MIT. See [LICENSE](LICENSE).
