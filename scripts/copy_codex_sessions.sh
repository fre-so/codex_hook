#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${HOME}/.codex/sessions"
DEST_DIR_DEFAULT="codex_message"
DEST_DIR_NAME="${CODEX_MESSAGE_DEST_DIR:-$DEST_DIR_DEFAULT}"

print_usage() {
  cat <<'EOU'
Usage: copy_codex_sessions.sh [--dest-dir <relative_path>]

Options:
  --dest-dir PATH   Override the destination directory name relative to repo root.
                    Defaults to "codex_message" or CODEX_MESSAGE_DEST_DIR env var.
EOU
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest-dir)
      if [ $# -lt 2 ]; then
        echo "--dest-dir requires a value" >&2
        exit 1
      fi
      DEST_DIR_NAME="$2"
      shift 2
      ;;
    --dest-dir=*)
      DEST_DIR_NAME="${1#*=}"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "Unable to determine git repository root. Is this a git repo?" >&2
  exit 1
fi

target_dir="${repo_root}/${DEST_DIR_NAME}"

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "No session directory at ${SOURCE_DIR}; skipping copy." >&2
  exit 0
fi

mkdir -p "${target_dir}"

copied_any=0
while IFS= read -r -d '' file_path; do
  first_line=$(head -n 1 "${file_path}" || true)
  if [ -z "${first_line}" ]; then
    continue
  fi

  session_cwd=$(printf '%s\n' "${first_line}" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
  if [ -z "${session_cwd}" ]; then
    continue
  fi

  if [ "${session_cwd}" = "${repo_root}" ]; then
    dest_path="${target_dir}/$(basename "${file_path}")"
    cp -p "${file_path}" "${dest_path}"
    printf 'Copied %s -> %s\n' "${file_path}" "${dest_path}"
    copied_any=1
  fi

done < <(find "${SOURCE_DIR}" -type f -name '*.jsonl' -print0)

if [ "${copied_any}" -eq 0 ]; then
  echo "No sessions matched ${repo_root}." >&2
fi

# Determine relative path for git commands (strip leading ./ if present).
relative_target="${DEST_DIR_NAME}"
while [[ "${relative_target}" == ./* ]]; do
  relative_target="${relative_target#./}"
done
[ -z "${relative_target}" ] && relative_target="."

dirty_jsonl=()
while IFS= read -r -d '' path; do
  case "${path}" in
    *.jsonl)
      dirty_jsonl+=("${path}")
      ;;
  esac
done < <(
  {
    git -C "${repo_root}" diff --name-only -z -- "${relative_target}" 2>/dev/null
    git -C "${repo_root}" ls-files --others -z --exclude-standard -- "${relative_target}" 2>/dev/null
  }
)

if [ "${#dirty_jsonl[@]}" -gt 0 ]; then
  echo "Codex session files in ${relative_target} must be added to the commit:" >&2
  for path in "${dirty_jsonl[@]}"; do
    echo " - ${path}" >&2
  done
  echo "Stage the files above (e.g., git add) and re-run the commit." >&2
  exit 1
fi
