#!/bin/bash

# ==========================================================
# Unraid / Jellyfin folder consolidation
#
# Finds the drive containing video files and consolidates
# all other files for that movie/show onto that drive.
#
# Default: DRY RUN (no files are moved)
# ==========================================================

# Set to 0 to actually move files
DRY_RUN=1

# Physical drives
DISKS=(/mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 \
       /mnt/disk5 /mnt/disk6)

# Folders to scan, relative to each disk root
FOLDERS=(
    "Data/Movies"
    "Data/TV_Shows/Anime"
    "Data/TV_Shows/Cartoons"
    "Data/TV_Shows/Comedy"
    "Data/TV_Shows/Documentaries"
    "Data/TV_Shows/Live Action"
    "Data/TV_Shows/Other_Vids"
)

# Video file extensions that mark the drive holding a movie/show.
# Add or remove formats freely: lowercase, no dots. Matching ignores case.
VIDEO_EXTS=(mkv mp4 m4v avi mov wmv flv webm mpg mpeg ts m2ts mts vob ogv ogm divx 3gp)

# Where each run writes its log. Must not sit under a scanned media folder:
# the log is the only file a dry run creates.
LOG_DIR=/mnt/user/tmp

# ----------------------------------------------------------
# Send everything to the console and a log file. A dry run
# writes this one file and nothing inside the media folders.
# ----------------------------------------------------------

LOG_FILE="$LOG_DIR/media-consolidation-$(date +%Y%m%d-%H%M%S)-$$.log"

if ! mkdir -p "$LOG_DIR" || ! : > "$LOG_FILE"; then
    echo "ABORT: cannot write a log file in $LOG_DIR"
    exit 2
fi

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo " Jellyfin Media Consolidation"
echo "=========================================="
echo "LOG:         $LOG_FILE"
echo "Started:     $(date)"

# Fail closed on an unrecognised DRY_RUN value. `[ "$DRY_RUN" -eq 1 ]` errors on a
# non-integer and takes the else branch, so a typo like "yes" would silently run live.
if [ "$DRY_RUN" != "1" ] && [ "$DRY_RUN" != "0" ]; then
    echo "ABORT: DRY_RUN must be 1 (dry run) or 0 (live), got '$DRY_RUN'"
    exit 2
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "MODE: DRY RUN - No files will be moved"
else
    echo "MODE: LIVE - Files WILL be moved"
fi

echo "DISKS:       ${DISKS[*]}"
echo "FOLDERS:     ${#FOLDERS[@]}"
echo "VIDEO_EXTS:  ${VIDEO_EXTS[*]}"
echo

# An empty list would report every folder as holding no video, so say why instead.
if [ "${#VIDEO_EXTS[@]}" -eq 0 ]; then
    echo "ABORT: VIDEO_EXTS is empty - no folder would be recognised as a movie or show"
    exit 2
fi

# Expanded once into a find expression: -iname "*.mkv" -o -iname "*.mp4" ...
VIDEO_FIND=(-iname "*.${VIDEO_EXTS[0]}")
for ext in "${VIDEO_EXTS[@]:1}"; do
    VIDEO_FIND+=(-o -iname "*.$ext")
done

# Extension -> 1, so is_video() is a lookup instead of a process per file.
declare -A VIDEO_EXT_SET=()
for ext in "${VIDEO_EXTS[@]}"; do
    VIDEO_EXT_SET["$ext"]=1
done

# Problems a dry run cannot resolve on its own. Collected during the scan and
# reported together at the end, so one pass tells the owner everything to fix.
REPORT_CONFLICTS=()
REPORT_NO_VIDEO=()

# ----------------------------------------------------------
# Path helpers
# ----------------------------------------------------------

# A file is a video when its extension, compared case-insensitively, is one of
# the configured formats. A name without an extension is not a video.
is_video() {
    local path=$1 ext
    [ "$path" != "${path%.*}" ] || return 1
    ext=${path##*.}
    [ -n "${VIDEO_EXT_SET[${ext,,}]:-}" ]
}

# The depth clamp that unit_of and the conflict pass share: a unit is a movie
# folder or a season folder, never deeper, so Season 01/Disc 1 belongs to
# Season 01 and a disc split is its season's conflict. Sets CLAMPED to the
# clamped path; fails for the top-level folder itself, which is no unit.
clamp_unit() {
    local rel=$1 top rest
    top=${rel%%/*}
    rest=${rel#*/}
    [ "$rest" = "$rel" ] && return 1
    if [ "$rest" = "${rest%%/*}" ]; then
        CLAMPED=$rel
    else
        CLAMPED="$top/${rest%%/*}"
    fi
    return 0
}

# True when the directory holds video on any configured disk.
has_video() {
    local dir=$1 disk
    for disk in "${DISKS[@]}"; do
        [ -n "${SUB_VIDEO["$dir"$'\x1f'"$disk"]:-}" ] && return 0
    done
    return 1
}

# The unit a file belongs to, relative to the configured root: the nearest
# directory at or below the clamp that holds video anywhere in its subtree, or
# the top-level folder itself when nothing below it does. A file directly under
# the root belongs to no unit: it is not part of a movie or show.
unit_of() {
    local root=$1 rel=$2 cand top
    top=${rel%%/*}
    [ "$rel" = "$top" ] && return 1
    if clamp_unit "${rel%/*}"; then
        cand=$CLAMPED
    else
        cand=$top
    fi
    while [ "$cand" != "$top" ]; do
        has_video "$root/$cand" && { printf '%s' "$cand"; return 0; }
        cand=${cand%/*}
    done
    printf '%s' "$top"
}

# ----------------------------------------------------------
# Index: which disk holds the video, and which files follow it
# ----------------------------------------------------------

# Keys that name a disk join two parts with 0x1f, which cannot appear in a
# configured path, so no real folder name can collide with the separator.
declare -A TOPS=()          # top-level folder name -> 1
declare -A TOP_PRESENT=()   # "<root>/<top>" 0x1f <disk> -> 1
declare -A TOP_VIDEO=()     # "<root>/<top>" 0x1f <disk> -> video files
declare -A TOP_OWN_VIDEO=() # "<root>/<top>" 0x1f <disk> -> 1, video directly in it
declare -A SUB_VIDEO=()     # "<root>/<dir>" 0x1f <disk> -> video files below it
declare -A TOP_MASTER=()    # "<root>/<top>" -> disk holding most of it
declare -A UNIT_MASTER=()   # "<root>/<unit>" -> disk the unit belongs on
declare -A CONFLICT=()      # "<root>/<unit>" -> 1, a human must decide

# The plan. PLAN_REL is relative to the configured root, which is what a MOVE:
# line shows; PLAN_ROOT keeps the root needed to build the real source path.
declare -a PLAN_SRC=()
declare -a PLAN_DST=()
declare -a PLAN_REL=()
declare -a PLAN_UNIT=()
declare -a PLAN_ROOT=()
declare -A PAIR_COUNT=()   # "<src>" 0x1f <dst> -> planned files
declare -A UNIT_FILES=()   # "<root>/<unit>" -> non-video files seen
declare -A UNIT_MOVING=()  # "<root>/<unit>" -> non-video files planned
declare -A LEFT_IN_PLACE=() # "<root>/<unit>" -> "<disk>" 0x1f "<unit>", reported

DUPLICATES=0
SKIPPED_FILES=0
MOVED=0

# Count the video files each directory holds, so the disk with the most video
# for a movie or show becomes its master. One find pass per disk root.
index_videos() {
    local disk=$1 root=$2 rel dir top anc
    while IFS= read -r -d '' rel; do
        # Inlined dir_of: this runs once per file and once per ancestor level,
        # and a command substitution per step costs ~2 ms each.
        if [ "$rel" = "${rel##*/}" ]; then
            dir=.
        else
            dir=${rel%/*}
        fi
        top=${rel%%/*}
        if [ "$dir" = "$top" ]; then
            TOP_OWN_VIDEO["$root/$top"$'\x1f'"$disk"]=1
        fi
        anc=$dir
        while :; do
            SUB_VIDEO["$root/$anc"$'\x1f'"$disk"]=$(( ${SUB_VIDEO["$root/$anc"$'\x1f'"$disk"]:-0} + 1 ))
            [ "$anc" = "$top" ] && break
            [ "$anc" = "." ] && break
            anc=${anc%/*}
        done
        TOP_VIDEO["$root/$top"$'\x1f'"$disk"]=$(( ${TOP_VIDEO["$root/$top"$'\x1f'"$disk"]:-0} + 1 ))
    done < <(find "$disk/$root" -type f \( "${VIDEO_FIND[@]}" \) -printf '%P\0' 2>/dev/null)
    return 0
}

# Name a unit whose video sits on more than one disk. A unit is at most one
# level below its top-level folder, so its own name is the last component.
report_conflict() {
    local root=$1 unit=$2 disks=$3 top=${2%%/*}
    echo "SKIP: Video files found on multiple drives"
    echo "       Conflicting: $unit on $disks"
    echo "       Manual inspection required"
    CONFLICT["$root/$unit"]=1
    if [ "$unit" = "$top" ]; then
        REPORT_CONFLICTS+=("  $root/$top - video files directly in it on $disks")
    else
        REPORT_CONFLICTS+=("  $root/$top - ${unit#*/} on $disks")
    fi
}

# Pick the disk each unit belongs on, and name the units a human must resolve.
# A unit whose own video sits on two or more disks cannot have its files follow
# it, so only that unit is skipped and reported; its siblings are gathered as
# usual. A unit is a movie folder or a season folder, never deeper: a season
# split into disc folders is one unit on two disks, and that is a conflict.
resolve_masters() {
    local root=$1 top disk count best best_count key dir rel unit disks present n
    local -a units=()
    local -A unit_seen=()
    local -A unit_disks=()

    # One pass over the subtree counts, each directory clamped to its unit:
    # Season 01/Disc 1 and Disc 2 both land on Season 01, while sibling seasons
    # land on themselves.
    for key in "${!SUB_VIDEO[@]}"; do
        [ -n "${SUB_VIDEO[$key]}" ] || continue
        dir=${key%$'\x1f'*}
        disk=${key##*$'\x1f'}
        rel=${dir#"$root/"}
        clamp_unit "$rel" || continue
        [ -n "${unit_seen[$CLAMPED]:-}" ] || units+=("$CLAMPED")
        unit_seen["$CLAMPED"]=1
        unit_disks["$CLAMPED"$'\x1f'"$disk"]=1
    done

    for top in "${!TOPS[@]}"; do
        best=""
        best_count=0
        for disk in "${DISKS[@]}"; do
            count=${TOP_VIDEO["$root/$top"$'\x1f'"$disk"]:-0}
            if [ "$count" -gt "$best_count" ]; then
                best=$disk
                best_count=$count
            fi
        done

        if [ -z "$best" ]; then
            present=""
            for disk in "${DISKS[@]}"; do
                [ -n "${TOP_PRESENT["$root/$top"$'\x1f'"$disk"]:-}" ] || continue
                present="${present:+$present, }${disk##*/}"
            done
            echo "SKIP: No video files found in $top (looked for: ${VIDEO_EXTS[*]})"
            REPORT_NO_VIDEO+=("  $root/$top - on ${present:-no configured disk}")
            continue
        fi

        # Episodes directly in the movie folder put that folder — the unit — on
        # two disks. Seasons below it are separate units and do not count.
        disks=""
        n=0
        for disk in "${DISKS[@]}"; do
            [ -n "${TOP_OWN_VIDEO["$root/$top"$'\x1f'"$disk"]:-}" ] || continue
            disks="${disks:+$disks, }${disk##*/}"
            n=$(( n + 1 ))
        done
        if [ "$n" -gt 1 ]; then
            report_conflict "$root" "$top" "$disks"
            continue
        fi

        TOP_MASTER["$root/$top"]=$best
        UNIT_MASTER["$root/$top"]=$best
    done

    # Every unit below a top-level folder: the disk holding most of its video,
    # or a conflict when its video is on two disks. Ties go to the earliest
    # configured disk, as they do above. A conflicted top-level folder does not
    # stop this: its seasons are separate units and still gather, only the
    # files that resolve to the top itself are held back.
    while IFS= read -r -d '' unit; do
        top=${unit%%/*}
        best=""
        best_count=0
        disks=""
        n=0
        for disk in "${DISKS[@]}"; do
            count=${SUB_VIDEO["$root/$unit"$'\x1f'"$disk"]:-0}
            if [ "$count" -gt "$best_count" ]; then
                best=$disk
                best_count=$count
            fi
            [ -n "${unit_disks["$unit"$'\x1f'"$disk"]:-}" ] || continue
            disks="${disks:+$disks, }${disk##*/}"
            n=$(( n + 1 ))
        done
        if [ "$n" -gt 1 ]; then
            report_conflict "$root" "$unit" "$disks"
            continue
        fi
        if [ -n "$best" ]; then
            UNIT_MASTER["$root/$unit"]=$best
            # Video on a disk other than the show's own majority: the unit's
            # files stay where they are. Informational, never an issue.
            if [ -n "${TOP_MASTER["$root/$top"]:-}" ] && [ "$best" != "${TOP_MASTER["$root/$top"]}" ]; then
                LEFT_IN_PLACE["$root/$unit"]="$best"$'\x1f'"$unit"
            fi
        fi
    done < <(printf '%s\0' "${units[@]}" | sort -z)
    return 0
}

# Add every non-video file that belongs on another disk to the plan. A video is
# never planned: it is the anchor the other files gather around. A file whose
# own unit is fine follows that unit even when its top-level folder is
# conflicted; only the files that resolve to the conflicted folder itself stay.
index_files() {
    local disk=$1 root=$2 rel top unit master dir
    # Every file in a directory resolves to the same unit, so the lookup runs
    # once per directory: a command substitution per file cost ~0.3 ms, about
    # 17 s of the run on the real library's 28k metadata files.
    local -A unit_cache=()
    while IFS= read -r -d '' rel; do
        top=${rel%%/*}
        dir=${rel%/*}
        [ "$dir" = "$rel" ] && dir="."
        if [ -n "${unit_cache[$dir]+set}" ]; then
            unit=${unit_cache[$dir]}
        else
            unit=$(unit_of "$root" "$rel") || unit=""
            unit_cache["$dir"]=$unit
        fi
        if [ -z "$unit" ]; then
            # Directly under the configured root: not part of a movie or show.
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
            continue
        fi
        if [ -n "${CONFLICT["$root/$unit"]:-}" ]; then
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
            continue
        fi
        master=${UNIT_MASTER["$root/$unit"]:-${TOP_MASTER["$root/$top"]:-}}
        if [ -z "$master" ]; then
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
            continue
        fi
        # Counted before the master check, so a unit whose files already sit on
        # its own disk still reports how many stayed there.
        UNIT_FILES["$root/$unit"]=$(( ${UNIT_FILES["$root/$unit"]:-0} + 1 ))
        [ "$master" = "$disk" ] && continue
        if [ -e "$master/$root/$rel" ]; then
            DUPLICATES=$((DUPLICATES + 1))
            continue
        fi
        if is_video "$rel"; then
            echo "SKIP: video file reached the plan: $rel"
            continue
        fi
        PLAN_SRC+=("$disk")
        PLAN_DST+=("$master")
        PLAN_REL+=("$rel")
        PLAN_UNIT+=("$unit")
        PLAN_ROOT+=("$root")
        PAIR_COUNT["$disk"$'\x1f'"$master"]=$(( ${PAIR_COUNT["$disk"$'\x1f'"$master"]:-0} + 1 ))
        UNIT_MOVING["$root/$unit"]=$(( ${UNIT_MOVING["$root/$unit"]:-0} + 1 ))
    done < <(find "$disk/$root" -type f ! \( "${VIDEO_FIND[@]}" \) -printf '%P\0' 2>/dev/null)
    return 0
}

# ----------------------------------------------------------
# Plan: print it, then (live) carry it out
# ----------------------------------------------------------

# One GATHER line per unit, its files on a dry run, then one BATCH line per
# disk pair. Sorted by unit then path; the 0x1f fields survive any filename.
print_plan() {
    local mode=$1 rec root unit rest rel idx key count last=""
    local -a order=()
    local -a pairs=()

    if [ "${#PLAN_REL[@]}" -gt 0 ]; then
        while IFS= read -r -d '' rec; do
            order+=("$rec")
        done < <(
            for idx in "${!PLAN_REL[@]}"; do
                printf '%s\x1f%s\x1f%s\x1f%s\0' \
                    "${PLAN_ROOT[idx]}" "${PLAN_UNIT[idx]}" "${PLAN_REL[idx]}" "$idx"
            done | sort -z -t $'\x1f' -k1,3
        )
    fi

    echo
    for rec in "${order[@]}"; do
        root=${rec%%$'\x1f'*}
        rest=${rec#*$'\x1f'}
        unit=${rest%%$'\x1f'*}
        rest=${rest#*$'\x1f'}
        rel=${rest%$'\x1f'*}
        idx=${rest##*$'\x1f'}
        if [ "$root/$unit" != "$last" ]; then
            count=${UNIT_MOVING["$root/$unit"]:-0}
            echo "GATHER: $unit -> ${PLAN_DST[idx]}  ($count file(s))"
            last="$root/$unit"
        fi
        if [ "$mode" = "dry" ]; then
            echo "MOVE: $rel"
        fi
    done

    if [ "${#PAIR_COUNT[@]}" -gt 0 ]; then
        echo
        while IFS= read -r -d '' key; do
            pairs+=("$key")
        done < <(printf '%s\0' "${!PAIR_COUNT[@]}" | sort -z)
        for key in "${pairs[@]}"; do
            echo "BATCH: ${key%%$'\x1f'*} -> ${key##*$'\x1f'}  (${PAIR_COUNT[$key]} file(s))"
        done
    fi
    return 0
}

# Scratch list for the batch in flight. The trap is installed on first use and
# SCRATCH is global, because a function's locals are gone by the time EXIT runs.
SCRATCH=""
FAILED_FILES=0

# Delete directories left empty by a move, deepest first, in chunks so a large
# batch cannot exceed the argument limit. -depth plus -empty means a directory
# that still holds a duplicate or an unmoved file survives, and no configured
# root is ever passed (every path ends below one).
prune_dirs() {
    local -a chunk=()
    local d
    for d in "$@"; do
        chunk+=("$d")
        if [ "${#chunk[@]}" -ge 500 ]; then
            find "${chunk[@]}" -depth -type d -empty -delete 2>/dev/null
            chunk=()
        fi
    done
    [ "${#chunk[@]}" -gt 0 ] && find "${chunk[@]}" -depth -type d -empty -delete 2>/dev/null
    return 0
}

# Move one pair's files in a single rsync. --remove-source-files deletes only
# what arrived; --ignore-existing is the guard against a stale copy overwriting
# the master's metadata. A non-zero status means some files did not arrive, so
# the source stays and the run exits non-zero.
run_batch() {
    local src=$1 dst=$2 root=$3
    shift 3
    local source="$src/$root" destination="$dst/$root" rel n failed=0 moved=0

    mkdir -p "$destination"
    n=$(tr -cd '\0' < "$SCRATCH/list" | wc -c)

    if rsync -avh --from0 --files-from="$SCRATCH/list" \
            --ignore-existing --remove-source-files \
            "$source/" "$destination/"; then
        MOVED=$((MOVED + n))
        [ "$#" -gt 0 ] && prune_dirs "$@"
        return 0
    fi

    # Anything still at the source is a failed move: name it, leave it, and let
    # the run report a non-zero exit.
    while IFS= read -r -d '' rel; do
        if [ -e "$source/$rel" ]; then
            failed=$((failed + 1))
            echo "FAILED:  $source/$rel"
        else
            moved=$((moved + 1))
        fi
    done < "$SCRATCH/list"

    MOVED=$((MOVED + moved))
    FAILED_FILES=$((FAILED_FILES + failed))
    failures=$((failures + 1))
    [ "$#" -gt 0 ] && prune_dirs "$@"
    return 1
}

# Walk the plan once, in sorted order, and hand each (source, target, root)
# group to run_batch. The list is built in the loop, never through a pipeline:
# a `... | sort` would run the loop in a subshell and lose the directories the
# prune needs.
run_batches() {
    local rec prefix idx rest src dst root rel dir
    local -a records=() dirs=()
    local -A seen=()

    [ "${#PLAN_REL[@]}" -gt 0 ] || return 0

    if [ -z "$SCRATCH" ]; then
        SCRATCH=$(mktemp -d) || { echo "ABORT: cannot create a scratch directory"; exit 2; }
        trap 'rm -rf "$SCRATCH"' EXIT
    fi

    while IFS= read -r -d '' rec; do
        records+=("$rec")
    done < <(
        for idx in "${!PLAN_REL[@]}"; do
            printf '%s\x1f%s\x1f%s\x1f%s\0' \
                "${PLAN_SRC[idx]}" "${PLAN_DST[idx]}" "${PLAN_ROOT[idx]}" "$idx"
        done | sort -z -t $'\x1f' -k1,3
    )

    prefix=""
    for rec in "${records[@]}"; do
        idx=${rec##*$'\x1f'}
        if [ "${rec%$'\x1f'*}" != "$prefix" ]; then
            [ -n "$prefix" ] && run_batch "$src" "$dst" "$root" "${dirs[@]}"
            prefix=${rec%$'\x1f'*}
            src=${prefix%%$'\x1f'*}
            rest=${prefix#*$'\x1f'}
            dst=${rest%%$'\x1f'*}
            root=${rest#*$'\x1f'}
            : > "$SCRATCH/list"
            dirs=()
            seen=()
        fi
        rel=${PLAN_REL[idx]}
        printf '%s\0' "$rel" >> "$SCRATCH/list"
        # The unit's top-level folder, not the file's own directory: find starts
        # there and -depth walks back up, so a parent that never held a file
        # itself (Show/Season 01 above trickplay/0001) still disappears. The
        # configured root is never passed, because every rel has a top folder.
        if [ "$rel" != "${rel##*/}" ]; then
            dir="$src/$root/${rel%%/*}"
            if [ -z "${seen[$dir]:-}" ]; then
                seen["$dir"]=1
                dirs+=("$dir")
            fi
        fi
    done
    [ -n "$prefix" ] && run_batch "$src" "$dst" "$root" "${dirs[@]}"
    return 0
}

# The four numbers the owner reads at the end of a run, then one line per unit
# whose video sits on a disk other than its show's majority. Those files stay
# where they are: expected, never an issue, never an exit-code change. A live run
# also names every unit it skipped, because the run has finished by then and the
# list is the only record of what it did not touch.
print_report() {
    local mode=$1 moved key disk unit n total=0
    local -a lines=()

    if [ "$mode" = "dry" ]; then
        moved="${#PLAN_REL[@]} file(s) to move"
    else
        moved="$MOVED file(s) moved"
    fi

    for key in "${!LEFT_IN_PLACE[@]}"; do
        n=$(( ${UNIT_FILES[$key]:-0} - ${UNIT_MOVING[$key]:-0} ))
        total=$(( total + n ))
        disk=${LEFT_IN_PLACE[$key]%%$'\x1f'*}
        unit=${LEFT_IN_PLACE[$key]#*$'\x1f'}
        lines+=("Left in place: $unit  (video on ${disk##*/}, $n file(s) stay there)")
    done

    echo
    echo "REPORT: $moved"
    echo "REPORT: $(( ${#CONFLICT[@]} + ${#REPORT_NO_VIDEO[@]} )) unit(s) skipped for manual inspection  ($(( ${#CONFLICT[@]} )) conflict, ${#REPORT_NO_VIDEO[@]} no video)"
    echo "REPORT: $(( SKIPPED_FILES + total )) file(s) left in place"
    echo "REPORT: $DUPLICATES file(s) already on the master, left on their own disk"

    if [ "${#lines[@]}" -gt 0 ]; then
        echo
        printf '%s\n' "${lines[@]}" | sort
    fi

    if [ "$mode" = "live" ] &&
        { [ "${#REPORT_CONFLICTS[@]}" -ne 0 ] || [ "${#REPORT_NO_VIDEO[@]}" -ne 0 ]; }; then
        echo
        echo "SKIPPED UNITS"
        echo "These units were left untouched; their files are still on their own drives:"
        printf '%s\n' "${REPORT_CONFLICTS[@]}" "${REPORT_NO_VIDEO[@]}" | sort
    fi
}

# ----------------------------------------------------------
# Scan each configured media directory
# ----------------------------------------------------------

# Counts groups whose transfer did not complete, so the run can exit non-zero
# instead of reporting success over a partial move.
failures=0

for relative_path in "${FOLDERS[@]}"; do

    echo
    echo "=========================================="
    echo "Scanning: $relative_path"
    echo "=========================================="

    # Collect top-level folder names across all configured drives
    TOPS=()

    for disk in "${DISKS[@]}"; do

        root="$disk/$relative_path"

        [ -d "$root" ] || continue

        while IFS= read -r -d '' name; do
            TOPS["$name"]=1
            TOP_PRESENT["$relative_path/$name"$'\x1f'"$disk"]=1
        done < <(
            find "$root" -mindepth 1 -maxdepth 1 \
                -type d -printf '%f\0'
        )

    done

    [ "${#TOPS[@]}" -gt 0 ] || continue

    for disk in "${DISKS[@]}"; do
        [ -d "$disk/$relative_path" ] || continue
        index_videos "$disk" "$relative_path"
    done

    resolve_masters "$relative_path"

    for disk in "${DISKS[@]}"; do
        [ -d "$disk/$relative_path" ] || continue
        index_files "$disk" "$relative_path"
    done

    # Clear, never unset: unset drops the associative attribute, and the next
    # root would then read the path keys as arithmetic.
    TOPS=()
    TOP_PRESENT=()
    TOP_VIDEO=()
    TOP_OWN_VIDEO=()
    SUB_VIDEO=()
    TOP_MASTER=()
    UNIT_MASTER=()

done

echo
echo "=========================================="
echo " Consolidation scan complete"
echo "=========================================="
echo "Log:         $LOG_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
    print_plan dry
    print_report dry
else
    print_plan live
    run_batches
    print_report live
fi

if [ "$DRY_RUN" -eq 1 ]; then

    if [ "${#REPORT_CONFLICTS[@]}" -eq 0 ] && [ "${#REPORT_NO_VIDEO[@]}" -eq 0 ]; then
        echo "No issues found - safe to set DRY_RUN=0 and run live."
        echo "Nothing was moved."
        echo "=========================================="
    else
        echo
        echo "=========================================="
        echo " ISSUES TO RESOLVE BEFORE A LIVE RUN"
        echo "=========================================="

        if [ "${#REPORT_CONFLICTS[@]}" -ne 0 ]; then
            echo "${#REPORT_CONFLICTS[@]} folder(s) hold video on more than one drive."
            echo "Keep one copy, remove the other, then run the dry run again:"
            printf '%s\n' "${REPORT_CONFLICTS[@]}" | sort
            echo
        fi

        if [ "${#REPORT_NO_VIDEO[@]}" -ne 0 ]; then
            echo "${#REPORT_NO_VIDEO[@]} folder(s) hold no file with a configured extension."
            echo "Check whether the video is missing, or its format is not in VIDEO_EXTS:"
            printf '%s\n' "${REPORT_NO_VIDEO[@]}" | sort
            echo
        fi

        echo "Do not set DRY_RUN=0 while this list is non-empty."
        echo "Nothing was moved."
        echo "=========================================="
        exit 1
    fi

else
    if [ "$failures" -ne 0 ]; then
        echo "Live consolidation finished with $failures failed batch(es) and $FAILED_FILES file(s) not moved."
        echo "See the FAILED lines above; re-run once the cause is fixed."
        echo "=========================================="
        exit 1
    fi
    echo "Live consolidation completed."
    echo "=========================================="
fi
