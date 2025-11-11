# Codex Session Copier Hook

This repository packages a shell-based `pre-commit` hook that copies Codex CLI
session logs that belong to the current workspace into `codex_message/` inside
that workspace. Shipping it as a standalone repository lets you add the hook to
any project via `pre-commit` or `prek` without duplicating the script.

## How it works
- Looks for chat transcripts under `~/.codex/sessions/**/*.jsonl`.
- Reads the first JSON line (session metadata) to extract the `cwd` where the
  session started.
- Copies every file whose `cwd` matches the repository running the hook into
  `<repo>/codex_message/`, overwriting any existing copy while preserving
  timestamps and permissions.
- After copying, exits with an error if there are unstaged or untracked
  `.jsonl` files under the destination directory so you remember to add them to
  the commit.
- Warns (but does not fail) if the Codex session directory does not exist or no
  sessions match the repository path.

## Installation
1. [Install [prek]](https://prek.j178.dev/) if you have not already. Or you can
   use `pre-commit` directly.
2. Add the hook repo and ID to your project's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/fre-so/codex_hook
    rev: 0.1.2
    hooks:
      - id: copy-codex-sessions
        # Optional: override the destination directory
        # args: [--dest-dir=codex_messages] default is 'codex_message/'
```

3. Run `prek install` inside your project so Git uses the hook.

The hook has no additional dependencies beyond POSIX utilities available on macOS
and Linux.

### Custom destination directory

By default, copied sessions land in `codex_message/` at the repo root. Override it
either by:

- Passing `--dest-dir <path>` via the hook `args` as shown above, or
- Setting the `CODEX_MESSAGE_DEST_DIR` environment variable when invoking
  `prek` (e.g., `CODEX_MESSAGE_DEST_DIR=codex_logs prek run`).

### Commit readiness checks

Because the hook runs before Git finishes creating a commit, it verifies that no
`.jsonl` files under the destination directory remain unstaged or untracked after
copying:

- If every file is already staged, the hook exits successfully.
- If any `.jsonl` files would be left out of the commit, the hook lists them,
  exits with a non-zero status, and asks you to `git add` the files before
  retrying the commit.
