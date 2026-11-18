#!/bin/bash
# =============================================================================
# tests/run-tests.sh — behavioural tests for media-folder-consolidation.sh
#
# Usage:  bash tests/run-tests.sh
# Exit:   0 = every case passed, 1 = at least one case failed
#
# Isolation: each case builds a throwaway tree of fake disks under a mktemp
# directory and copies the script under test into that tree with the "/mnt/disk"
# prefix rewritten to the fake disks. Nothing outside the temp tree is read or
# written and /mnt is never touched. The rewrite is verified afterwards, so a
# future edit that hard-codes a /mnt path fails the harness loudly instead of
# quietly moving real files.
#
# Failure injection uses a stub `rsync` on PATH rather than provoking a real
# disk error: the contract under test is how the script reacts to a non-zero
# rsync status, not rsync's own behaviour on a sick filesystem.
#
# These cases assert the documented contract (each movie or season's non-video
# files end up on the drive holding its video; a video file never moves;
# ambiguity is skipped; a dry run moves nothing; a failed transfer is not
# reported as success) — not the implementation's internals.
# =============================================================================
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../media-folder-consolidation.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mfc-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT=""
CASE=""
BEFORE_FAIL=0

# ---------------------------------------------------------------- assertions

# assert <description> <command...>
# Runs the command; records a pass when it succeeds, a failure with the
# description otherwise. Never aborts, so one case reports all its broken
# expectations at once.
assert() {
    local desc=$1
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'not ok - %s\n         %s\n' "$CURRENT" "$desc"
    fi
}

# begin <case-name> / end — one TAP line per case, failures printed by assert
begin() {
    CURRENT=$1
    CASE="$WORK/$1"
    BEFORE_FAIL=$FAIL
    mkdir -p "$CASE"
}

end() {
    if [ "$FAIL" -eq "$BEFORE_FAIL" ]; then
        printf 'ok   - %s\n' "$CURRENT"
    fi
}

has()    { grep -qF -- "$1" "$CASE/out.log"; }   # script printed this text
lacks()  { ! grep -qF -- "$1" "$CASE/out.log"; } # script did not print it
exists() { [ -e "$1" ]; }
missing() { [ ! -e "$1" ]; }

# ---------------------------------------------------------------- fixtures

# make_disks <count> — creates $CASE/disk1..N with both configured roots, so the
# "[ -d ] || continue" guards take their normal path.
make_disks() {
    local n=$1 i
    for ((i = 1; i <= n; i++)); do
        mkdir -p "$CASE/disk$i/Data/Movies" \
                 "$CASE/disk$i/Data/TV_Shows/Live Action"
    done
}

# prepare <dir> <DRY_RUN value | "default"> [VIDEO_EXTS values]
# Writes $dir/under-test.sh: the real script with /mnt/disk pointed at the fake
# disks, DRY_RUN replaced unless "default" is asked for, VIDEO_EXTS replaced
# when a list is given, and LOG_DIR pointed inside the case directory. Every
# rewrite is verified — a silent miss would test the wrong thing (and a missed
# LOG_DIR rewrite would write a log into /mnt on the host).
prepare() {
    local dir=$1 value=$2 exts=${3:-}
    local sedargs=(-e "s|/mnt/disk|$dir/disk|g"
                   -e "s|^LOG_DIR=.*|LOG_DIR=$dir/log|")

    if [ "$value" != "default" ]; then
        sedargs+=(-e "s|^DRY_RUN=1\$|DRY_RUN=$value|")
    fi

    if [ -n "$exts" ]; then
        sedargs+=(-e "s|^VIDEO_EXTS=.*|VIDEO_EXTS=($exts)|")
    fi

    sed "${sedargs[@]}" "$SCRIPT" > "$dir/under-test.sh"

    if grep -q '/mnt/' "$dir/under-test.sh"; then
        printf 'harness error: /mnt path survived the rewrite\n' >&2
        exit 99
    fi
    if ! grep -qF "LOG_DIR=$dir/log" "$dir/under-test.sh"; then
        printf 'harness error: LOG_DIR rewrite did not apply\n' >&2
        exit 99
    fi
    if [ "$value" != "default" ] && ! grep -q "^DRY_RUN=$value\$" "$dir/under-test.sh"; then
        printf 'harness error: DRY_RUN rewrite did not apply\n' >&2
        exit 99
    fi
    if [ -n "$exts" ] && ! grep -qF "VIDEO_EXTS=($exts)" "$dir/under-test.sh"; then
        printf 'harness error: VIDEO_EXTS rewrite did not apply\n' >&2
        exit 99
    fi
}

# run_and_log <dir> [extra PATH prefix] — runs the prepared script, keeps stdout
# and stderr in $dir/out.log, returns the script's exit status.
run_and_log() {
    local dir=$1 extra=${2:-}
    if [ -n "$extra" ]; then
        PATH="$extra:$PATH" bash "$dir/under-test.sh" > "$dir/out.log" 2>&1
    else
        bash "$dir/under-test.sh" > "$dir/out.log" 2>&1
    fi
}

# A library where one movie folder sits on disk2 only: the simplest thing that
# must be consolidated (metadata next to the mkv, on another disk).
build_alpha() {
    mkdir -p "$CASE/disk1/Data/Movies/Alpha" "$CASE/disk2/Data/Movies/Alpha/trickplay/0001"
    : > "$CASE/disk1/Data/Movies/Alpha/Alpha.mkv"
    : > "$CASE/disk1/Data/Movies/Alpha/poster.jpg"
    : > "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    : > "$CASE/disk2/Data/Movies/Alpha/Alpha.srt"
    : > "$CASE/disk2/Data/Movies/Alpha/trickplay/0001/thumb.jpg"
}

# ---------------------------------------------------------------- test cases

# Shipped default must be a dry run: the safety property the whole script rests
# on. Uses the untouched DRY_RUN line, so a changed default fails here.
case_default_is_dry_run() {
    begin default-is-dry-run
    make_disks 2
    build_alpha

    prepare "$CASE" default
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                       [ "$rc" -eq 0 ]
    assert "announces dry run"            has "MODE: DRY RUN"
    assert "master's own file untouched"  exists "$CASE/disk1/Data/Movies/Alpha/poster.jpg"
    assert "source file not moved"        exists "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    assert "nothing copied to master"     missing "$CASE/disk1/Data/Movies/Alpha/Alpha.nfo"
    end
}

# The disk holding the video file becomes the master; every other disk's copy of
# the same folder is merged onto it and the emptied source removed.
case_consolidates_onto_media_disk() {
    begin consolidates-onto-media-disk
    make_disks 2
    build_alpha

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                  [ "$rc" -eq 0 ]
    assert "picks the mkv disk"      has "GATHER: Alpha -> $CASE/disk1"
    assert "nfo moved"               exists "$CASE/disk1/Data/Movies/Alpha/Alpha.nfo"
    assert "subtitle moved"          exists "$CASE/disk1/Data/Movies/Alpha/Alpha.srt"
    assert "trickplay moved"         exists "$CASE/disk1/Data/Movies/Alpha/trickplay/0001/thumb.jpg"
    assert "mkv stays put"           exists "$CASE/disk1/Data/Movies/Alpha/Alpha.mkv"
    assert "emptied source removed"  missing "$CASE/disk2/Data/Movies/Alpha"
    end
}

# The simplest gather: a movie folder whose metadata sits on another disk.
case_gathers_metadata_onto_video_disk() {
    begin gathers-metadata-onto-video-disk
    make_disks 2
    build_alpha
    prepare "$CASE" 1
    run_and_log "$CASE"
    local rc=$?
    assert "exit 0"                    [ "$rc" -eq 0 ]
    assert "names the unit and disk"   has "GATHER: Alpha -> $CASE/disk1"
    assert "lists the nfo move"        has "MOVE: Alpha/Alpha.nfo"
    assert "lists the trickplay move"  has "MOVE: Alpha/trickplay/0001/thumb.jpg"
    assert "never lists a video"       lacks "MOVE: Alpha/Alpha.mkv"
    assert "moved nothing"             exists "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    end
}

# Files already on the master are not in the plan.
case_already_consolidated_is_not_planned() {
    begin already-consolidated-is-not-planned
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Alpha"
    : > "$CASE/disk1/Data/Movies/Alpha/Alpha.mkv"
    : > "$CASE/disk1/Data/Movies/Alpha/poster.jpg"
    prepare "$CASE" 1
    run_and_log "$CASE"
    assert "nothing to gather"   lacks "GATHER: Alpha"
    assert "nothing to move"     lacks "MOVE: Alpha/poster.jpg"
    end
}

# A newline in a filename survives the index, the plan and the report.
case_newline_in_filename_is_planned() {
    begin newline-in-filename-is-planned
    make_disks 2
    local odd=$'poster\nnewline.jpg'
    mkdir -p "$CASE/disk1/Data/Movies/Alpha" "$CASE/disk2/Data/Movies/Alpha"
    : > "$CASE/disk1/Data/Movies/Alpha/Alpha.mkv"
    : > "$CASE/disk2/Data/Movies/Alpha/$odd"
    prepare "$CASE" 1
    run_and_log "$CASE"
    assert "plan holds the newline name" bash -c \
        'grep -qF "MOVE: Alpha/poster" "$1" && grep -qF "newline.jpg" "$1"' _ "$CASE/out.log"
    end
}

# Split video files are ambiguous: the script must skip and say so, not guess.
case_skips_media_on_multiple_disks() {
    begin skips-media-on-multiple-disks
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Beta" "$CASE/disk2/Data/Movies/Beta"
    : > "$CASE/disk1/Data/Movies/Beta/Beta.S01E01.mkv"
    : > "$CASE/disk2/Data/Movies/Beta/Beta.S01E02.mkv"
    : > "$CASE/disk2/Data/Movies/Beta/Beta.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                    [ "$rc" -eq 0 ]
    assert "says it skipped"           has "SKIP: Video files found on multiple drives"
    assert "asks for manual inspection" has "Manual inspection required"
    assert "second mkv untouched"      exists "$CASE/disk2/Data/Movies/Beta/Beta.S01E02.mkv"
    assert "metadata untouched"        exists "$CASE/disk2/Data/Movies/Beta/Beta.nfo"
    end
}

# A folder with no video anywhere is not a movie to consolidate. The skip names
# the extensions it looked for, so a forgotten format is visible in the log.
case_skips_folder_without_media() {
    begin skips-folder-without-media
    make_disks 2
    mkdir -p "$CASE/disk2/Data/Movies/Gamma"
    : > "$CASE/disk2/Data/Movies/Gamma/poster.jpg"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"           [ "$rc" -eq 0 ]
    assert "says it skipped"  has "SKIP: No video files found"
    assert "names the formats" has "looked for: mkv"
    assert "nothing moved"    exists "$CASE/disk2/Data/Movies/Gamma/poster.jpg"
    end
}

# Extension matching is case-insensitive; .MKV is still a video file.
case_detects_uppercase_extension() {
    begin detects-uppercase-extension
    make_disks 2
    mkdir -p "$CASE/disk2/Data/Movies/Echo" "$CASE/disk1/Data/Movies/Echo"
    : > "$CASE/disk2/Data/Movies/Echo/Echo.MKV"
    : > "$CASE/disk1/Data/Movies/Echo/Echo.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"               [ "$rc" -eq 0 ]
    assert "picks the .MKV disk"  has "GATHER: Echo -> $CASE/disk2"
    assert "metadata moved"       exists "$CASE/disk2/Data/Movies/Echo/Echo.nfo"
    end
}

# Detection is not limited to mkv: an mp4-only folder still finds its master.
case_detects_other_video_formats() {
    begin detects-other-video-formats
    make_disks 2
    mkdir -p "$CASE/disk2/Data/Movies/Mu" "$CASE/disk1/Data/Movies/Mu"
    : > "$CASE/disk2/Data/Movies/Mu/Mu.mp4"
    : > "$CASE/disk1/Data/Movies/Mu/Mu.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"              [ "$rc" -eq 0 ]
    assert "picks the .mp4 disk" has "GATHER: Mu -> $CASE/disk2"
    assert "metadata moved"      exists "$CASE/disk2/Data/Movies/Mu/Mu.nfo"
    assert "source removed"      missing "$CASE/disk1/Data/Movies/Mu"
    end
}

# Two different formats on two disks is the same ambiguity as two copies of one
# format: one would have to win, so skip and say so.
case_two_formats_on_two_disks_skip() {
    begin two-formats-on-two-disks-skip
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Nu" "$CASE/disk2/Data/Movies/Nu"
    : > "$CASE/disk1/Data/Movies/Nu/Nu.S01E01.mkv"
    : > "$CASE/disk2/Data/Movies/Nu/Nu.S01E01.mp4"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                     [ "$rc" -eq 0 ]
    assert "says it skipped"            has "SKIP: Video files found on multiple drives"
    assert "asks for manual inspection" has "Manual inspection required"
    assert "mkv untouched"              exists "$CASE/disk1/Data/Movies/Nu/Nu.S01E01.mkv"
    assert "mp4 untouched"              exists "$CASE/disk2/Data/Movies/Nu/Nu.S01E01.mp4"
    end
}

# The list drives detection: with mkv removed, an mkv-only folder holds no video
# and must be left alone. Catches a hard-coded pattern left behind.
case_extension_list_drives_detection() {
    begin extension-list-drives-detection
    make_disks 2
    build_alpha

    prepare "$CASE" 0 "mp4"
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"               [ "$rc" -eq 0 ]
    assert "skips the mkv folder" has "SKIP: No video files found"
    assert "names the new list"   has "looked for: mp4)"
    assert "no master chosen"     lacks "GATHER:"
    assert "metadata untouched"   exists "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    end
}

# An empty format list is a config error, not a reason to scan and skip every
# folder in silence.
case_empty_extension_list_refuses_to_run() {
    begin empty-extension-list-refuses-to-run
    make_disks 2
    build_alpha

    prepare "$CASE" 0
    sed -i 's|^VIDEO_EXTS=.*|VIDEO_EXTS=()|' "$CASE/under-test.sh"

    run_and_log "$CASE"
    local rc=$?

    assert "list really emptied" grep -qF 'VIDEO_EXTS=()' "$CASE/under-test.sh"
    assert "exits non-zero"      [ "$rc" -ne 0 ]
    assert "says why"            has "ABORT: VIDEO_EXTS is empty"
    assert "scans nothing"       lacks "Checking:"
    end
}

# Paths with spaces ("Live Action") and nested show folders survive every
# quoted expansion and the NUL-delimited folder scan.
case_handles_spaces_in_paths() {
    begin handles-spaces-in-paths
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Live Action/Show One" \
             "$CASE/disk3/Data/TV_Shows/Live Action/Show One"
    : > "$CASE/disk1/Data/TV_Shows/Live Action/Show One/S01E01.mkv"
    : > "$CASE/disk3/Data/TV_Shows/Live Action/Show One/S01E01.en.srt"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"        [ "$rc" -eq 0 ]
    assert "picks disk1"   has "GATHER: Show One -> $CASE/disk1"
    assert "subtitle moved" exists "$CASE/disk1/Data/TV_Shows/Live Action/Show One/S01E01.en.srt"
    assert "source removed" missing "$CASE/disk3/Data/TV_Shows/Live Action/Show One"
    end
}

# --ignore-existing protects the master's own metadata: a same-named file
# already on the master must never be replaced by another disk's version.
case_never_overwrites_master_metadata() {
    begin never-overwrites-master-metadata
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Delta" "$CASE/disk2/Data/Movies/Delta"
    : > "$CASE/disk1/Data/Movies/Delta/Delta.mkv"
    printf 'master artwork\n' > "$CASE/disk1/Data/Movies/Delta/poster.jpg"
    printf 'other disk artwork\n' > "$CASE/disk2/Data/Movies/Delta/poster.jpg"
    : > "$CASE/disk2/Data/Movies/Delta/Delta.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                    [ "$rc" -eq 0 ]
    assert "master's poster kept"      [ "$(cat "$CASE/disk1/Data/Movies/Delta/poster.jpg")" = "master artwork" ]
    assert "new metadata still moved"  exists "$CASE/disk1/Data/Movies/Delta/Delta.nfo"
    end
}

# A transfer that failed is not a transfer that happened. The run must not
# report success, and must not claim the folder finished.
case_failed_rsync_is_not_success() {
    begin failed-rsync-is-not-success
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Zeta" "$CASE/disk2/Data/Movies/Zeta"
    : > "$CASE/disk1/Data/Movies/Zeta/Zeta.mkv"
    : > "$CASE/disk2/Data/Movies/Zeta/Zeta.srt"

    # Stub rsync: same status as a real partial transfer (code 23).
    mkdir -p "$CASE/bin"
    printf '#!/bin/bash\necho "rsync: simulated transfer failure" >&2\nexit 23\n' \
        > "$CASE/bin/rsync"
    chmod +x "$CASE/bin/rsync"

    prepare "$CASE" 0
    run_and_log "$CASE" "$CASE/bin"
    local rc=$?

    assert "exits non-zero"            [ "$rc" -ne 0 ]
    assert "does not claim completion" lacks "Live consolidation completed."
    assert "source files left in place" exists "$CASE/disk2/Data/Movies/Zeta/Zeta.srt"
    end
}

# Safety switch fails closed: any DRY_RUN value that is not 0 or 1 must refuse
# to run rather than fall through into the live branch.
case_invalid_dry_run_refuses_to_run() {
    begin invalid-dry-run-refuses-to-run
    make_disks 2
    build_alpha

    prepare "$CASE" yes
    run_and_log "$CASE"
    local rc=$?

    assert "exits non-zero"           [ "$rc" -ne 0 ]
    assert "never enters live mode"   lacks "MODE: LIVE"
    assert "moves nothing"            exists "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    assert "copies nothing"           missing "$CASE/disk1/Data/Movies/Alpha/Alpha.nfo"
    end
}

# A configured disk that is not mounted must not abort the run: the remaining
# disks are still consolidated and the script exits cleanly.
case_absent_disk_is_not_fatal() {
    begin absent-disk-is-not-fatal
    make_disks 1                       # DISKS still lists six; only disk1 exists
    mkdir -p "$CASE/disk1/Data/Movies/Omega"
    : > "$CASE/disk1/Data/Movies/Omega/Omega.mkv"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                      [ "$rc" -eq 0 ]
    assert "no missing-path error"       lacks "No such file or directory"
    assert "scanned what exists"         lacks "SKIP: No video files found"
    end
}

# Live run prunes empty directories left behind, but only inside the folder it
# moved, never the shared parent.
case_prunes_only_the_moved_folder() {
    begin prunes-only-the-moved-folder
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Iota" \
             "$CASE/disk2/Data/Movies/Iota/subs/empty" \
             "$CASE/disk2/Data/Movies/Kappa"
    : > "$CASE/disk1/Data/Movies/Iota/Iota.mkv"
    : > "$CASE/disk2/Data/Movies/Iota/Iota.srt"
    : > "$CASE/disk2/Data/Movies/Kappa/unrelated.txt"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                     [ "$rc" -eq 0 ]
    assert "moved folder pruned"        missing "$CASE/disk2/Data/Movies/Iota"
    assert "empty subdir gone with it"  missing "$CASE/disk2/Data/Movies/Iota/subs"
    assert "shared parent kept"         exists "$CASE/disk2/Data/Movies"
    assert "sibling folder untouched"   exists "$CASE/disk2/Data/Movies/Kappa/unrelated.txt"
    end
}

# The same season on two drives is a genuine conflict — merging would leave one
# copy behind — so skip, name the season, and ask for a human. 137 folders in
# the library this was developed against look like this.
case_skips_season_split_across_drives() {
    begin skips-season-split-across-drives
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Live Action/Epsilon/Season 01" \
             "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01"
    : > "$CASE/disk1/Data/TV_Shows/Live Action/Epsilon/Season 01/E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01/E02.mkv"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                     [ "$rc" -eq 0 ]
    assert "says it skipped"            has "SKIP: Video files found on multiple drives"
    assert "names the split season"      has "Conflicting: Season 01"
    assert "asks for manual inspection" has "Manual inspection required"
    assert "both copies untouched"      exists "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01/E02.mkv"
    end
}

# Seasons on different disks are siblings, not a split: each season is its own
# unit and neither is a conflict.
case_seasons_stay_on_their_own_disks() {
    begin seasons-stay-on-their-own-disks
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Live Action/Delta/Season 01" \
             "$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 02"
    : > "$CASE/disk1/Data/TV_Shows/Live Action/Delta/Season 01/S01E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 02/S02E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 02/S02E01.srt"
    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?
    assert "exit 0"                 [ "$rc" -eq 0 ]
    assert "season 1 mkv stays"     exists "$CASE/disk1/Data/TV_Shows/Live Action/Delta/Season 01/S01E01.mkv"
    assert "season 2 mkv stays"     exists "$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 02/S02E01.mkv"
    assert "no season is a conflict" lacks "Manual inspection required"
    end
}

# A season's metadata follows its own season, not the show's majority disk.
case_season_metadata_follows_its_season() {
    begin season-metadata-follows-its-season
    make_disks 2
    local base1="$CASE/disk1/Data/TV_Shows/Live Action/Delta"
    local base2="$CASE/disk2/Data/TV_Shows/Live Action/Delta"
    mkdir -p "$base1/Season 01" "$base1/Season 02" "$base2/Season 02"
    : > "$base1/Season 01/S01E01.mkv"
    : > "$base1/Season 01/S01E02.mkv"
    : > "$base1/Season 01/S01E03.mkv"
    : > "$base2/Season 02/S02E01.mkv"
    : > "$base1/Season 02/season.nfo"
    : > "$base1/Delta.nfo"
    prepare "$CASE" 0
    run_and_log "$CASE"
    assert "season.nfo goes to season 2's disk" exists "$base2/Season 02/season.nfo"
    assert "show nfo stays on the majority disk" exists "$base1/Delta.nfo"
    end
}

# A disc folder is the unit when the season root holds no video.
case_disc_folder_is_the_unit() {
    begin disc-folder-is-the-unit
    make_disks 2
    local s1="$CASE/disk1/Data/TV_Shows/Live Action/Delta/Season 01"
    local s2="$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 01"
    local s3="$CASE/disk2/Data/TV_Shows/Live Action/Delta/Season 02"
    mkdir -p "$s1/Disc 1" "$s2" "$s3"
    : > "$s1/Disc 1/S01E01.mkv"
    : > "$s2/season.nfo"
    : > "$s3/S02E01.mkv"
    : > "$s3/S02E02.mkv"
    prepare "$CASE" 0
    run_and_log "$CASE"
    assert "season.nfo follows its own season" exists "$s1/season.nfo"
    assert "season 2 video stays"              exists "$s3/S02E01.mkv"
    end
}

# .ogm and .divx appear in the library this was developed against. Left out of
# the list, those folders look empty and are skipped forever.
case_detects_ogm_and_divx() {
    begin detects-ogm-and-divx
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Anime/Tank" \
             "$CASE/disk2/Data/TV_Shows/Anime/Tank" \
             "$CASE/disk1/Data/Movies/Standup" \
             "$CASE/disk2/Data/Movies/Standup"
    : > "$CASE/disk1/Data/TV_Shows/Anime/Tank/Tank - S01E01.ogm"
    : > "$CASE/disk2/Data/TV_Shows/Anime/Tank/Tank.en.srt"
    : > "$CASE/disk1/Data/Movies/Standup/Standup.divx"
    : > "$CASE/disk2/Data/Movies/Standup/Standup.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                  [ "$rc" -eq 0 ]
    assert ".ogm folder consolidated" exists "$CASE/disk1/Data/TV_Shows/Anime/Tank/Tank.en.srt"
    assert ".divx folder consolidated" exists "$CASE/disk1/Data/Movies/Standup/Standup.nfo"
    assert "no empty-folder skip"      lacks "SKIP: No video files found"
    end
}

# Other_Vids holds home clips rather than movies or shows, two levels deep
# (Other_Vids/My Videos/<name>). Once it is a configured root it must be
# scanned like any show category.
case_consolidates_other_vids() {
    begin consolidates-other-vids
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Other_Vids/My Videos" \
             "$CASE/disk2/Data/TV_Shows/Other_Vids/My Videos"
    : > "$CASE/disk1/Data/TV_Shows/Other_Vids/My Videos/clip.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Other_Vids/My Videos/clip-notes.txt"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                      [ "$rc" -eq 0 ]
    assert "scans Other_Vids"            has "GATHER: My Videos -> $CASE/disk1"
    assert "note moved"                  exists "$CASE/disk1/Data/TV_Shows/Other_Vids/My Videos/clip-notes.txt"
    end
}

# Real names: accents, apostrophes, ampersands, commas, empty parentheses.
# Nothing here may be mangled by quoting or by the NUL-delimited scan.
case_handles_unicode_and_punctuation() {
    begin handles-unicode-and-punctuation
    make_disks 2
    local movie="Léon The Professional (1994) [tmdbid-101]"
    local show="Agatha Christie's Poirot (1989) [tvdbid-76133]"
    local odd="Love, Death & Robots (2019) [tvdbid-357888]"
    local stub="Wake Up Dead Man A Knives Out Mystery () [tmdbid-812583]"
    mkdir -p "$CASE/disk1/Data/Movies/$movie"       "$CASE/disk2/Data/Movies/$movie" \
             "$CASE/disk1/Data/TV_Shows/Anime/$show" "$CASE/disk2/Data/TV_Shows/Anime/$show" \
             "$CASE/disk1/Data/TV_Shows/Anime/$odd"  "$CASE/disk2/Data/TV_Shows/Anime/$odd" \
             "$CASE/disk1/Data/Movies/$stub"         "$CASE/disk2/Data/Movies/$stub"
    : > "$CASE/disk1/Data/Movies/$movie/$movie.mkv"
    : > "$CASE/disk2/Data/Movies/$movie/$movie.en.srt"
    : > "$CASE/disk1/Data/TV_Shows/Anime/$show/S01E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Anime/$show/S01E01.nfo"
    : > "$CASE/disk1/Data/TV_Shows/Anime/$odd/S01E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Anime/$odd/S01E01.nfo"
    : > "$CASE/disk1/Data/Movies/$stub/$stub.mkv"
    : > "$CASE/disk2/Data/Movies/$stub/$stub.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"               [ "$rc" -eq 0 ]
    assert "accented name merged" exists "$CASE/disk1/Data/Movies/$movie/$movie.en.srt"
    assert "apostrophe merged"    exists "$CASE/disk1/Data/TV_Shows/Anime/$show/S01E01.nfo"
    assert "ampersand merged"     exists "$CASE/disk1/Data/TV_Shows/Anime/$odd/S01E01.nfo"
    assert "empty parens merged"  exists "$CASE/disk1/Data/Movies/$stub/$stub.nfo"
    end
}

# A folder holding only Jellyfin leftovers (trickplay, .ignore) has no video and
# must be left alone — the library this was developed against has 2 such stubs.
case_empty_stub_folder_is_skipped() {
    begin empty-stub-folder-is-skipped
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Stub/trickplay"
    : > "$CASE/disk1/Data/Movies/Stub/trickplay/.ignore"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"          [ "$rc" -eq 0 ]
    assert "says it skipped" has "SKIP: No video files found"
    assert "leftover stays"  exists "$CASE/disk1/Data/Movies/Stub/trickplay/.ignore"
    end
}

# The duplicate itself is the only file in that library present at the same
# path on two drives. rsync's --ignore-existing skips it and
# --remove-source-files only removes what it transferred, so that copy stays
# behind by design.
case_duplicate_ignore_file_does_not_block_merge() {
    begin duplicate-ignore-file-does-not-block-merge
    make_disks 2
    mkdir -p "$CASE/disk1/Data/Movies/Toys/trickplay" "$CASE/disk2/Data/Movies/Toys/trickplay"
    : > "$CASE/disk1/Data/Movies/Toys/Toys.mkv"
    : > "$CASE/disk1/Data/Movies/Toys/trickplay/.ignore"
    : > "$CASE/disk2/Data/Movies/Toys/trickplay/.ignore"
    : > "$CASE/disk2/Data/Movies/Toys/Toys.nfo"

    prepare "$CASE" 0
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                        [ "$rc" -eq 0 ]
    assert "still consolidates"            has "GATHER: Toys -> $CASE/disk1"
    assert "metadata moved"                exists "$CASE/disk1/Data/Movies/Toys/Toys.nfo"
    assert "skipped duplicate left behind" exists "$CASE/disk2/Data/Movies/Toys/trickplay/.ignore"
    end
}

# ---------------------------------------------------------------- issues report

# A clean dry run must say so in as many words, because that sentence is the
# only cue the owner has to switch DRY_RUN to 0.
case_dry_run_says_safe_to_go_live() {
    begin dry-run-says-safe-to-go-live
    make_disks 2
    build_alpha

    prepare "$CASE" default
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"                  [ "$rc" -eq 0 ]
    assert "gives the go-ahead"      has "No issues found - safe to set DRY_RUN=0 and run live."
    assert "no issues block"         lacks "ISSUES TO RESOLVE"
    end
}

# A season on two drives needs a human decision, so the report must name the
# folder, the season and the drives rather than only counting them.
case_dry_run_reports_conflicts_before_live() {
    begin dry-run-reports-conflicts-before-live
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Live Action/Epsilon/Season 01" \
             "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01"
    : > "$CASE/disk1/Data/TV_Shows/Live Action/Epsilon/Season 01/E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01/E02.mkv"

    prepare "$CASE" default
    run_and_log "$CASE"
    local rc=$?

    assert "exit non-zero"           [ "$rc" -ne 0 ]
    assert "headline"                has "ISSUES TO RESOLVE BEFORE A LIVE RUN"
    assert "names the folder"        has "Data/TV_Shows/Live Action/Epsilon - Season 01 on disk1, disk2"
    assert "withholds the go-ahead"  has "Do not set DRY_RUN=0 while this list is non-empty."
    assert "no go-ahead sentence"    lacks "safe to set DRY_RUN=0"
    assert "moved nothing"           exists "$CASE/disk2/Data/TV_Shows/Live Action/Epsilon/Season 01/E02.mkv"
    end
}

# A folder whose only files are artwork or trickplay would be ignored forever;
# the report says which folder and which disks hold it.
case_dry_run_reports_folders_without_video() {
    begin dry-run-reports-folders-without-video
    make_disks 2
    mkdir -p "$CASE/disk2/Data/Movies/Gamma"
    : > "$CASE/disk2/Data/Movies/Gamma/poster.jpg"

    prepare "$CASE" default
    run_and_log "$CASE"
    local rc=$?

    assert "exit non-zero"     [ "$rc" -ne 0 ]
    assert "headline"          has "ISSUES TO RESOLVE BEFORE A LIVE RUN"
    assert "names the folder"  has "Data/Movies/Gamma - on disk2"
    end
}

# Disjoint seasons are a planned merge, not a problem: the report must not
# train the owner to ignore it.
case_disjoint_merge_is_not_an_issue() {
    begin disjoint-merge-is-not-an-issue
    make_disks 2
    mkdir -p "$CASE/disk1/Data/TV_Shows/Comedy/Zeta/Season 01" \
             "$CASE/disk2/Data/TV_Shows/Comedy/Zeta/Season 02"
    : > "$CASE/disk1/Data/TV_Shows/Comedy/Zeta/Season 01/Zeta.S01E01.mkv"
    : > "$CASE/disk2/Data/TV_Shows/Comedy/Zeta/Season 02/Zeta.S02E01.mkv"

    prepare "$CASE" default
    run_and_log "$CASE"
    local rc=$?

    assert "exit 0"            [ "$rc" -eq 0 ]
    assert "no issues block"   lacks "ISSUES TO RESOLVE"
    assert "no conflict"       lacks "Manual inspection required"
    end
}

# ---------------------------------------------------------------- logging

case_dry_run_writes_a_log_and_nothing_else() {
    begin dry-run-writes-a-log
    make_disks 2
    build_alpha

    prepare "$CASE" default
    local before after log rc
    before=$(find "$CASE/disk1" "$CASE/disk2" -printf '%p\t%s\t%T@\n' | sort | md5sum)

    run_and_log "$CASE"
    rc=$?

    after=$(find "$CASE/disk1" "$CASE/disk2" -printf '%p\t%s\t%T@\n' | sort | md5sum)
    log=$(ls "$CASE"/log/*.log 2>/dev/null | head -1)

    assert "exit 0"                    [ "$rc" -eq 0 ]
    assert "one log file"              [ "$(ls "$CASE"/log/*.log 2>/dev/null | wc -l)" -eq 1 ]
    assert "log names itself"          grep -qF "LOG:         $log" "$CASE/out.log"
    assert "log records the mode"      grep -qF "MODE: DRY RUN - No files will be moved" "$log"
    assert "log records the run"       grep -qF "Scanning: Data/Movies" "$log"
    assert "log records the outcome"   grep -qF "Nothing was moved." "$log"
    assert "media tree untouched"      [ "$before" = "$after" ]
    assert "source left in place"      exists "$CASE/disk2/Data/Movies/Alpha/Alpha.nfo"
    assert "nothing copied to master"  missing "$CASE/disk1/Data/Movies/Alpha/Alpha.nfo"
    end
}

case_log_captures_an_abort() {
    begin log-captures-abort
    make_disks 1
    prepare "$CASE" yes

    run_and_log "$CASE"
    local rc=$?
    local log
    log=$(ls "$CASE"/log/*.log 2>/dev/null | head -1)

    assert "refuses to run"     [ "$rc" -ne 0 ]
    assert "log file created"   [ -n "$log" ]
    assert "log holds the abort" grep -qF "ABORT: DRY_RUN must be 1 (dry run) or 0 (live)" "$log"
    end
}

case_unusable_log_directory_aborts() {
    begin unusable-log-directory
    make_disks 1
    prepare "$CASE" 0
    # A regular file where the log directory should be: the run must stop
    # rather than proceed with no record of what it did.
    : > "$CASE/notadir"
    sed "s|^LOG_DIR=.*|LOG_DIR=$CASE/notadir|" "$CASE/under-test.sh" > "$CASE/under-test.sh.new"
    mv "$CASE/under-test.sh.new" "$CASE/under-test.sh"

    run_and_log "$CASE"
    local rc=$?

    assert "refuses to run"     [ "$rc" -ne 0 ]
    assert "says why"           has "ABORT: cannot write a log file in"
    assert "scans nothing"      lacks "Scanning:"
    end
}

# ---------------------------------------------------------------- runner

bash -n "$SCRIPT" || { printf 'gate failed: %s does not parse\n' "$SCRIPT" >&2; exit 1; }

case_default_is_dry_run
case_consolidates_onto_media_disk
case_gathers_metadata_onto_video_disk
case_already_consolidated_is_not_planned
case_newline_in_filename_is_planned
case_skips_media_on_multiple_disks
case_skips_folder_without_media
case_detects_uppercase_extension
case_detects_other_video_formats
case_two_formats_on_two_disks_skip
case_extension_list_drives_detection
case_empty_extension_list_refuses_to_run
case_handles_spaces_in_paths
case_never_overwrites_master_metadata
case_failed_rsync_is_not_success
case_invalid_dry_run_refuses_to_run
case_absent_disk_is_not_fatal
case_prunes_only_the_moved_folder
case_skips_season_split_across_drives
case_seasons_stay_on_their_own_disks
case_season_metadata_follows_its_season
case_disc_folder_is_the_unit
case_detects_ogm_and_divx
case_consolidates_other_vids
case_handles_unicode_and_punctuation
case_empty_stub_folder_is_skipped
case_duplicate_ignore_file_does_not_block_merge
case_dry_run_writes_a_log_and_nothing_else
case_log_captures_an_abort
case_unusable_log_directory_aborts
case_dry_run_says_safe_to_go_live
case_dry_run_reports_conflicts_before_live
case_dry_run_reports_folders_without_video
case_disjoint_merge_is_not_an_issue

printf '\n# %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
