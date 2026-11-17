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

# Problems a dry run cannot resolve on its own. Collected during the scan and
# reported together at the end, so one pass tells the owner everything to fix.
REPORT_CONFLICTS=()
REPORT_NO_VIDEO=()

# ----------------------------------------------------------
# Process a movie folder or TV show folder
# ----------------------------------------------------------

process_folder() {

    local relative_path="$1"
    local folder_name="$2"

    local master=""
    local video_drives=0
    local folder_failed=0
    local disk file key season owner present=""
    local -a video_disks=()

    echo
    echo "------------------------------------------"
    echo "Checking: $relative_path/$folder_name"
    echo "------------------------------------------"

    # Find which drives contain a video file
    for disk in "${DISKS[@]}"; do

        local folder="$disk/$relative_path/$folder_name"

        [ -d "$folder" ] || continue

        present="${present:+$present, }${disk##*/}"

        if find "$folder" -type f \( "${VIDEO_FIND[@]}" \) -print -quit | grep -q .; then
            video_disks+=("$disk")
            ((video_drives++))
        fi

    done

    # No video file found
    if [ "$video_drives" -eq 0 ]; then
        echo "SKIP: No video files found (looked for: ${VIDEO_EXTS[*]})"
        REPORT_NO_VIDEO+=("  $relative_path/$folder_name - on ${present:-no configured disk}")
        return
    fi

    if [ "$video_drives" -eq 1 ]; then
        master="${video_disks[0]}"
    else
        # Several drives hold video. That is only ambiguous when one season
        # appears on two of them: different seasons merge cleanly, a season on
        # two drives would leave a copy behind ("Season 01" on disk2 and disk5).
        local -A season_disks=()
        local -A season_owner=()
        local -A conflicted=()
        local -A disk_videos=()

        # Record, per drive, which top-level folder below the show holds video.
        # A file directly in the show folder counts as "(top level)".
        for disk in "${video_disks[@]}"; do

            local folder="$disk/$relative_path/$folder_name"
            local count=0

            while IFS= read -r -d '' file; do
                count=$((count + 1))
                local rel=${file#"$folder/"}
                local place="(top level)"
                if [ "$rel" != "${rel#*/}" ]; then
                    place=${rel%%/*}
                fi
                season_disks["$place"$'\t'"$disk"]=1
            done < <(find "$folder" -type f \( "${VIDEO_FIND[@]}" \) -print0)

            disk_videos["$disk"]=$count

        done

        for key in "${!season_disks[@]}"; do
            season=${key%%$'\t'*}
            owner=${key#*$'\t'}
            if [ -n "${season_owner[$season]:-}" ] && [ "${season_owner[$season]}" != "$owner" ]; then
                conflicted["$season"]=1
            else
                season_owner["$season"]="$owner"
            fi
        done

        # A genuinely split season: picking a winner would be a guess
        if [ "${#conflicted[@]}" -ne 0 ]; then
            local detail="" part disks
            local -a parts=("${!conflicted[@]}")
            mapfile -t parts < <(printf '%s\n' "${parts[@]}" | sort)

            for part in "${parts[@]}"; do
                disks=""
                for disk in "${video_disks[@]}"; do
                    if [ -n "${season_disks["$part"$'\t'"$disk"]:-}" ]; then
                        disks="${disks:+$disks, }${disk##*/}"
                    fi
                done
                detail="${detail:+$detail; }$part on $disks"
            done

            echo "SKIP: Video files found on multiple drives"
            echo "       Conflicting: $(printf '%s\n' "${parts[@]}" | paste -sd ',' - | sed 's/,/, /g')"
            echo "       Manual inspection required"
            REPORT_CONFLICTS+=("  $relative_path/$folder_name - $detail")
            return
        fi

        # Disjoint seasons: put the show on the drive that already holds most
        # of it, then merge the rest as usual.
        master="${video_disks[0]}"
        local best=${disk_videos["${video_disks[0]}"]}
        for disk in "${video_disks[@]:1}"; do
            if [ "${disk_videos[$disk]}" -gt "$best" ]; then
                master="$disk"
                best=${disk_videos[$disk]}
            fi
        done

        echo "MULTI-DRIVE: no season is split across drives"
        echo "             $video_drives drives hold different seasons; $best video"
        echo "             file(s) on the chosen drive"
    fi

    echo "MASTER DRIVE: $master"

    # Consolidate files from all other drives
    for disk in "${DISKS[@]}"; do

        [ "$disk" = "$master" ] && continue

        local source="$disk/$relative_path/$folder_name"
        local destination="$master/$relative_path/$folder_name"

        [ -d "$source" ] || continue

        echo
        echo "Source:      $source"
        echo "Destination: $destination"

        if [ "$DRY_RUN" -eq 1 ]; then
            rsync -avhn --ignore-existing "$source/" "$destination/"
        else
            mkdir -p "$destination"

            # A non-zero rsync means part of the folder did not arrive. Report it,
            # skip the prune so the untouched source stays intact, and keep going:
            # one bad folder must not stop the rest of the scan.
            if ! rsync -avh --ignore-existing \
                    --remove-source-files \
                    "$source/" "$destination/"; then
                folder_failed=$((folder_failed + 1))
                echo "FAILED:  $source"
                echo "         Transfer did not complete - source left in place"
                continue
            fi

            # Remove empty directories left behind
            find "$source" -depth -type d -empty -delete
        fi

    done

    if [ "$folder_failed" -ne 0 ]; then
        echo "FAILED:  $folder_name ($folder_failed source folder(s) not fully moved)"
        return 1
    fi

    echo "Finished: $folder_name"

}

# ----------------------------------------------------------
# Scan each configured media directory
# ----------------------------------------------------------

# Counts movie/show folders whose transfer did not complete, so the run can exit
# non-zero instead of reporting success over a partial move.
failures=0

for relative_path in "${FOLDERS[@]}"; do

    echo
    echo "=========================================="
    echo "Scanning: $relative_path"
    echo "=========================================="

    # Collect folder names across all configured drives
    declare -A folders=()

    for disk in "${DISKS[@]}"; do

        root="$disk/$relative_path"

        [ -d "$root" ] || continue

        while IFS= read -r -d '' name; do
            folders["$name"]=1
        done < <(
            find "$root" -mindepth 1 -maxdepth 1 \
                -type d -printf '%f\0'
        )

    done

    # Process each movie/show folder
    for folder_name in "${!folders[@]}"; do
        process_folder "$relative_path" "$folder_name" || failures=$((failures + 1))
    done

    unset folders

done

echo
echo "=========================================="
echo " Consolidation scan complete"
echo "=========================================="
echo "Log:         $LOG_FILE"

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
