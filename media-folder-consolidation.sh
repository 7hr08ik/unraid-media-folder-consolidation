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

# The directory part of a relative path; "." when the file sits at the root.
dir_of() {
    local rel=$1
    [ "$rel" = "${rel##*/}" ] && { printf '.'; return 0; }
    printf '%s' "${rel%/*}"
}

# The first path component of a relative path.
top_of() {
    printf '%s' "${1%%/*}"
}

# The unit a file belongs to, relative to the configured root. A file directly
# under the root belongs to no unit: it is not part of a movie or a show.
unit_of() {
    local rel=$2
    [ "$rel" = "${rel%%/*}" ] && return 1
    printf '%s' "${rel%%/*}"
}

# ----------------------------------------------------------
# Index: which disk holds the video, and which files follow it
# ----------------------------------------------------------

# Keys that name a disk join two parts with 0x1f, which cannot appear in a
# configured path, so no real folder name can collide with the separator.
declare -A TOPS=()         # top-level folder name -> 1
declare -A TOP_PRESENT=()  # "<root>/<top>" 0x1f <disk> -> 1
declare -A TOP_VIDEO=()    # "<root>/<top>" 0x1f <disk> -> video files
declare -A SUB_VIDEO=()    # "<root>/<dir>" 0x1f <disk> -> video files below it
declare -A GROUP_VIDEO=()  # "<root>/<top>" 0x1f <child> 0x1f <disk> -> 1
declare -A TOP_MASTER=()   # "<root>/<top>" -> disk holding most of it
declare -A UNIT_MASTER=()  # "<root>/<unit>" -> disk the unit belongs on
declare -A CONFLICT=()     # "<root>/<top>" -> 1, a human must decide

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

DUPLICATES=0
LEFT_IN_PLACE=0
MOVED=0

# Count the video files each directory holds, so the disk with the most video
# for a movie or show becomes its master. One find pass per disk root.
index_videos() {
    local disk=$1 root=$2 rel dir top anc rest group
    while IFS= read -r -d '' rel; do
        dir=$(dir_of "$rel")
        top=${rel%%/*}
        rest=${rel#*/}
        group="(top level)"
        if [ "$rest" != "${rest%%/*}" ]; then
            group=${rest%%/*}
        fi
        anc=$dir
        while :; do
            SUB_VIDEO["$root/$anc"$'\x1f'"$disk"]=$(( ${SUB_VIDEO["$root/$anc"$'\x1f'"$disk"]:-0} + 1 ))
            [ "$anc" = "$top" ] && break
            [ "$anc" = "." ] && break
            anc=$(dir_of "$anc")
        done
        TOP_VIDEO["$root/$top"$'\x1f'"$disk"]=$(( ${TOP_VIDEO["$root/$top"$'\x1f'"$disk"]:-0} + 1 ))
        GROUP_VIDEO["$root/$top"$'\x1f'"$group"$'\x1f'"$disk"]=1
    done < <(find "$disk/$root" -type f \( "${VIDEO_FIND[@]}" \) -printf '%P\0' 2>/dev/null)
    return 0
}

# Pick the disk each top-level folder belongs on, or name the folder a human
# must resolve. A child folder holding video on two disks is ambiguous: one
# copy would have to win, so the whole show is skipped rather than guessed at.
resolve_masters() {
    local root=$1 top disk count best best_count key rest group
    local -a conflicts=()
    local -A group_count=()

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
            local present=""
            for disk in "${DISKS[@]}"; do
                [ -n "${TOP_PRESENT["$root/$top"$'\x1f'"$disk"]:-}" ] || continue
                present="${present:+$present, }${disk##*/}"
            done
            echo "SKIP: No video files found in $top (looked for: ${VIDEO_EXTS[*]})"
            REPORT_NO_VIDEO+=("  $root/$top - on ${present:-no configured disk}")
            continue
        fi

        group_count=()
        for key in "${!GROUP_VIDEO[@]}"; do
            rest=${key#"$root/$top"$'\x1f'}
            [ "$rest" != "$key" ] || continue
            group=${rest%$'\x1f'*}
            group_count["$group"]=$(( ${group_count[$group]:-0} + 1 ))
        done

        conflicts=()
        for group in "${!group_count[@]}"; do
            [ "${group_count[$group]}" -gt 1 ] && conflicts+=("$group")
        done

        if [ "${#conflicts[@]}" -gt 0 ]; then
            mapfile -t conflicts < <(printf '%s\n' "${conflicts[@]}" | sort)
            local detail=""
            for group in "${conflicts[@]}"; do
                local disks=""
                for disk in "${DISKS[@]}"; do
                    [ -n "${GROUP_VIDEO["$root/$top"$'\x1f'"$group"$'\x1f'"$disk"]:-}" ] || continue
                    disks="${disks:+$disks, }${disk##*/}"
                done
                detail="${detail:+$detail; }$group on $disks"
            done
            local listed=""
            for group in "${conflicts[@]}"; do
                listed="${listed:+$listed, }$group"
            done
            echo "SKIP: Video files found on multiple drives"
            echo "       Conflicting: $listed"
            echo "       Manual inspection required"
            CONFLICT["$root/$top"]=1
            REPORT_CONFLICTS+=("  $root/$top - $detail")
            continue
        fi

        TOP_MASTER["$root/$top"]=$best
        UNIT_MASTER["$root/$top"]=$best
    done
    return 0
}

# Add every non-video file that belongs on another disk to the plan. A video is
# never planned: it is the anchor the other files gather around.
index_files() {
    local disk=$1 root=$2 rel top unit master
    while IFS= read -r -d '' rel; do
        top=$(top_of "$rel")
        if ! unit=$(unit_of "$root" "$rel"); then
            LEFT_IN_PLACE=$((LEFT_IN_PLACE + 1))
            continue
        fi
        if [ -z "${TOP_MASTER["$root/$top"]:-}" ]; then
            LEFT_IN_PLACE=$((LEFT_IN_PLACE + 1))
            continue
        fi
        master=${UNIT_MASTER["$root/$unit"]:-${TOP_MASTER["$root/$top"]}}
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
        UNIT_FILES["$root/$unit"]=$(( ${UNIT_FILES["$root/$unit"]:-0} + 1 ))
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

# Move one unit's planned files. A non-zero rsync means part of them did not
# arrive: say so, leave the source intact, and let the run exit non-zero.
transfer_group() {
    local src=$1 dst=$2 unit=$3 root=$4 list=$5
    local source="$src/$root" destination="$dst/$root"

    mkdir -p "$destination"

    if ! rsync -avh --from0 --files-from="$list" \
            --ignore-existing --remove-source-files \
            "$source/" "$destination/"; then
        echo "FAILED:  $source"
        echo "         Transfer did not complete - source left in place"
        return 1
    fi

    if [ -d "$source/$unit" ]; then
        find "$source/$unit" -depth -type d -empty -delete
    fi
    return 0
}

# Execute the plan: one rsync per (source disk, target disk, unit) group, fed a
# NUL-delimited file list so any name survives. Grouped by sorting the plan.
run_plan() {
    local rec prefix idx rest src dst unit root tmp n
    local -a records=()

    [ "${#PLAN_REL[@]}" -gt 0 ] || return 0

    if ! tmp=$(mktemp); then
        echo "ABORT: cannot create a temporary file for the batch list"
        exit 2
    fi

    while IFS= read -r -d '' rec; do
        records+=("$rec")
    done < <(
        for idx in "${!PLAN_REL[@]}"; do
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\0' \
                "${PLAN_SRC[idx]}" "${PLAN_DST[idx]}" "${PLAN_UNIT[idx]}" \
                "${PLAN_ROOT[idx]}" "$idx"
        done | sort -z -t $'\x1f' -k1,4
    )

    prefix=""
    n=0
    for rec in "${records[@]}"; do
        idx=${rec##*$'\x1f'}
        if [ "${rec%$'\x1f'*}" != "$prefix" ]; then
            if [ -n "$prefix" ]; then
                if transfer_group "$src" "$dst" "$unit" "$root" "$tmp"; then
                    MOVED=$((MOVED + n))
                else
                    failures=$((failures + 1))
                fi
            fi
            prefix=${rec%$'\x1f'*}
            src=${prefix%%$'\x1f'*}
            rest=${prefix#*$'\x1f'}
            dst=${rest%%$'\x1f'*}
            rest=${rest#*$'\x1f'}
            unit=${rest%%$'\x1f'*}
            root=${rest#*$'\x1f'}
            : > "$tmp"
            n=0
        fi
        printf '%s\0' "${PLAN_REL[idx]}" >> "$tmp"
        n=$((n + 1))
    done

    if [ -n "$prefix" ]; then
        if transfer_group "$src" "$dst" "$unit" "$root" "$tmp"; then
            MOVED=$((MOVED + n))
        else
            failures=$((failures + 1))
        fi
    fi

    rm -f "$tmp"
    return 0
}

# The four numbers the owner reads at the end of a run.
print_report() {
    local mode=$1 moved
    if [ "$mode" = "dry" ]; then
        moved="${#PLAN_REL[@]} file(s) to move"
    else
        moved="$MOVED file(s) moved"
    fi
    echo
    echo "REPORT: $moved"
    echo "REPORT: $(( ${#CONFLICT[@]} + ${#REPORT_NO_VIDEO[@]} )) unit(s) skipped for manual inspection  ($(( ${#CONFLICT[@]} )) conflict, ${#REPORT_NO_VIDEO[@]} no video)"
    echo "REPORT: $LEFT_IN_PLACE file(s) left in place"
    echo "REPORT: $DUPLICATES file(s) already on the master, left on their own disk"
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
    SUB_VIDEO=()
    GROUP_VIDEO=()
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
    run_plan
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
        echo "Live consolidation finished with $failures failed folder(s)."
        echo "See the FAILED lines above; re-run once the cause is fixed."
        echo "=========================================="
        exit 1
    fi
    echo "Live consolidation completed."
    echo "=========================================="
fi
