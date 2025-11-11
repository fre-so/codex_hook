#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${HOME}/.codex/sessions"
DEST_DIR_DEFAULT="codex_messages"
DEST_DIR_NAME="${CODEX_MESSAGE_DEST_DIR:-$DEST_DIR_DEFAULT}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to convert Codex sessions to Markdown." >&2
  exit 1
fi

convert_session_to_markdown() {
  local source_file="$1"
  local destination_file="$2"
  local session_cwd="$3"
  local git_user="$4"

  python3 - <<'PY' "$source_file" "$destination_file" "$session_cwd" "$git_user"
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
session_cwd = sys.argv[3]
git_user = (sys.argv[4] if len(sys.argv) > 4 else "").strip() or "unknown-user"

ENV_CONTEXT_RE = re.compile(r"<environment_context>.*?</environment_context>", re.DOTALL)
REQUEST_MARKER = "## My request for Codex:"
CONTEXT_HEADER = "# Context from my IDE setup:"


def clean_user_text(text: str) -> str:
    """Strip IDE noise, keep only the actual prompt."""
    text = ENV_CONTEXT_RE.sub("", text)
    text = text.strip()
    if not text:
        return ""

    if REQUEST_MARKER in text:
        text = text.split(REQUEST_MARKER, 1)[1]
    elif CONTEXT_HEADER in text:
        # Context without an explicit request should be ignored.
        return ""

    return text.strip()


messages = []
branch_name = "unknown-branch"
with source.open("r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue

        entry_type = entry.get("type")
        if entry_type == "session_meta":
            payload = entry.get("payload") or {}
            git_info = payload.get("git") or {}
            branch_name = git_info.get("branch") or branch_name
            continue

        payload = entry.get("payload") or {}
        if entry_type != "response_item":
            continue
        if payload.get("type") != "message":
            continue

        role = payload.get("role")
        if role not in ("user", "assistant"):
            continue

        chunks = []
        for block in payload.get("content") or []:
            text = block.get("text")
            if text:
                chunks.append(text)

        text_body = "\n\n".join(chunks).strip()
        if role == "user":
            text_body = clean_user_text(text_body)
        if not text_body:
            continue

        messages.append(
            {
                "role": "User" if role == "user" else "Assistant",
                "timestamp": entry.get("timestamp") or "unknown time",
                "text": text_body,
            }
        )

lines = [f"# Codex Session {branch_name} — {git_user}", ""]
if session_cwd:
    lines.append(f"- Working directory: `{session_cwd}`")
    lines.append("")

lines.append("---")
lines.append("")

if not messages:
    lines.append("_No user/assistant messages were recorded in this session._")
else:
    for message in messages:
        lines.append(f"## {message['role']} — {message['timestamp']}")
        lines.append("")
        lines.append(message["text"])
        lines.append("")

output = "\n".join(lines).rstrip() + "\n"
destination.write_text(output, encoding="utf-8")
PY
}

print_usage() {
  cat <<'EOU'
Usage: copy_codex_sessions.sh [--dest-dir <relative_path>]

Options:
  --dest-dir PATH   Override the destination directory name relative to repo root.
                    Defaults to "codex_messages" or CODEX_MESSAGE_DEST_DIR env var.
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

if ! git_user_name=$(git -C "${repo_root}" config user.name 2>/dev/null); then
  git_user_name=""
fi
git_user_name="${git_user_name:-unknown-user}"
# Generate a filesystem-friendly slug for filenames.
git_user_slug=$(printf '%s' "${git_user_name}" | tr '[:upper:]' '[:lower:]')
git_user_slug=$(printf '%s' "${git_user_slug}" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g')
[ -n "${git_user_slug}" ] || git_user_slug="user"

target_dir="${repo_root}/${DEST_DIR_NAME}"

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "No session directory at ${SOURCE_DIR}; skipping conversion." >&2
  exit 0
fi

mkdir -p "${target_dir}"

generated_any=0
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
    file_name="$(basename "${file_path}")"
    base_name="${file_name%.jsonl}"
    trimmed_base="${base_name#rollout-}"
    if [ "${trimmed_base}" = "${base_name}" ]; then
      sanitized_base="${git_user_slug}-${base_name}"
    else
      sanitized_base="${git_user_slug}-${trimmed_base}"
    fi
    dest_path="${target_dir}/${sanitized_base}.md"
    legacy_path="${target_dir}/${base_name}.md"
    convert_session_to_markdown "${file_path}" "${dest_path}" "${session_cwd}" "${git_user_name}"
    if [ -e "${legacy_path}" ] && [ "${legacy_path}" != "${dest_path}" ]; then
      rm -f "${legacy_path}"
    fi
    printf 'Wrote %s -> %s\n' "${file_path}" "${dest_path}"
    generated_any=1
  fi

done < <(find "${SOURCE_DIR}" -type f -name '*.jsonl' -print0)

if [ "${generated_any}" -eq 0 ]; then
  echo "No sessions matched ${repo_root}." >&2
fi

# Determine relative path for git commands (strip leading ./ if present).
relative_target="${DEST_DIR_NAME}"
while [[ "${relative_target}" == ./* ]]; do
  relative_target="${relative_target#./}"
done
[ -z "${relative_target}" ] && relative_target="."

dirty_markdown=()
while IFS= read -r -d '' path; do
  case "${path}" in
    *.md)
      dirty_markdown+=("${path}")
      ;;
  esac
done < <(
  {
    git -C "${repo_root}" diff --name-only -z -- "${relative_target}" 2>/dev/null
    git -C "${repo_root}" ls-files --others -z --exclude-standard -- "${relative_target}" 2>/dev/null
  }
)

if [ "${#dirty_markdown[@]}" -gt 0 ]; then
  echo "Codex session markdown files in ${relative_target} must be added to the commit:" >&2
  for path in "${dirty_markdown[@]}"; do
    echo " - ${path}" >&2
  done
  echo "Stage the files above (e.g., git add) and re-run the commit." >&2
  exit 1
fi
