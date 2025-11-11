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
    cp -p "${file_path}" "${target_dir}/"
    printf 'Copied %s\n' "${file_path}"
    copied_any=1
  fi

done < <(find "${SOURCE_DIR}" -type f -name '*.jsonl' -print0)

if [ "${copied_any}" -eq 0 ]; then
  echo "No sessions matched ${repo_root}." >&2
fi
