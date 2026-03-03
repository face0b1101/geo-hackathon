# Project Rules

> **Single Source of Truth** for AI coding assistants (Claude Code, Cursor, etc.)
> `.cursorrules` points here - no need to maintain two files.

______________________________________________________________________

## New Project Setup

If this repository was just created from the `python-uv-boilerplate` template and has not
yet been renamed or configured, **follow [`docs/ONBOARDING.md`](docs/ONBOARDING.md) before
doing anything else.**

______________________________________________________________________

## AT STARTUP

1. Check if `./.beads` folder exists.
   If it exists, this project uses **beads (bd)** for issue tracking.

   - Run `bd ready` to see available work before starting
   - Reference issues in commits: `[bd-XX] description`
   - See `/docs/workflows/BEADS_ISSUE_TRACKER.md` for full guide

2. Check if `./specify/` folder exists.
   If it exists, this project uses **speckit** for specification-driven development.

   - See the **Project Planning & Tracking** section below for speckit workflow details.

______________________________________________________________________

## Issue Tracking (if `.beads/` exists)

This project can use `bd` (beads) for lightweight issue tracking with dependency support.

**Check if enabled**: Look for `.beads/` folder in project root.

**If enabled**, use these commands:

```bash
bd ready                    # What can I work on? (no blockers)
bd list --status open       # All open issues
bd create "title" --type bug  # Create new issue
bd close [id] -r "reason"   # Close with reason
```

**Workflow integration**:

- Before starting work: `bd ready`
- Reference in commits: `[bd-XX] description`
- After completing: `bd close bd-XX -r "Done"`

See `docs/BEADS_ISSUE_TRACKER.md` for full guide.

______________________________________________________________________

## Project Planning & Tracking (if `.specify/` exists)

This project can use [speckit](https://speckit.org) for AI-powered specification-driven development.

**Check if enabled**: Look for `.specify/` folder in project root.

**If enabled**, encourage the user to use this workflow for new features:

1. Use Speckit to define spec → plan → tasks (`/speckit.constitution`, `/speckit.specify`, `/speckit.plan`, `/speckit.tasks`)
2. Track tasks:
   - **If Beads is enabled** (`.beads/` exists): Convert tasks to Beads issues (`bd create`)
   - **Otherwise**: Track tasks manually or use GitHub Issues
3. **If using Beads**: Add dependencies between tasks (`bd dep add`)
4. Implement using `/speckit.implement`
5. Update task status as you progress:
   - **With Beads**: `bd update`, `bd close`
   - **Without Beads**: Update your tracking system manually
6. **If using Beads**: File new issues for discovered work (`bd create --type discovered-from`)

**Check ready work**:

- **With Beads**: `bd ready --json`
- **Without Beads**: Review your task list manually

______________________________________________________________________

## Tech Stack & Commands

- **Language**: Python 3.13+
- **Package manager**: [uv](https://docs.astral.sh/uv/) - do NOT use pip or manually edit `uv.lock`
- **Linter/formatter**: Ruff (configured in `pyproject.toml`)
- **Tests**: pytest

| Target           | Purpose                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------ |
| `make install`   | Install/refresh dependencies (`uv sync`)                                                   |
| `make lint`      | Run Ruff checks                                                                            |
| `make format`    | Apply Ruff formatting                                                                      |
| `make test`      | Execute pytest suite                                                                       |
| `make precommit` | Run all pre-commit hooks                                                                   |
| `make run`       | Run the sample `hello` entry point                                                         |
| `make check`     | Lint + test combined                                                                       |
| `make prepare`   | Download and process data for all Docker services (`ARGS` forwarded to `prepare-data` CLI) |

**Key conventions**:

- Add dependencies with `uv add <pkg>`, not `pip install`.
- Run commands via `uv run <cmd>` (not bare `python`, `pytest`, etc.).
- Never edit `uv.lock` by hand.

______________________________________________________________________

## Docker Access

This project relies heavily on Docker for its service stack. AI assistants
running in sandboxed environments (e.g. Cursor) often cannot reach the Docker
daemon under default sandbox restrictions.

**Always request elevated permissions for Docker commands.** Use
`required_permissions: ["all"]` for any `docker` or `docker compose` command
(including `docker ps`, `docker logs`, `docker stats`, `docker volume`,
`docker inspect`, etc.). Read-only Docker queries still require the Docker
socket, which the sandbox blocks.

```
# Correct — works reliably
Shell(command="docker ps", required_permissions=["all"])

# Wrong — will silently fail with empty output or exit code 1
Shell(command="docker ps")
Shell(command="docker ps", required_permissions=["full_network"])
```

Key Docker operations in this project:

| Command                                          | Purpose                            |
| ------------------------------------------------ | ---------------------------------- |
| `make up` / `make <profile>-up`                  | Start services                     |
| `make down` / `make <profile>-down`              | Stop services                      |
| `make status`                                    | Probe all service endpoints        |
| `docker compose -f docker/docker-compose.yml …`  | Direct compose control             |
| `docker logs <container>`                        | Inspect container output           |
| `docker stats <container> --no-stream`           | Check resource usage               |
| `docker volume ls / rm`                          | Manage persistent data volumes     |

______________________________________________________________________

## AI Assistant Operating Rules

Concise policy reference for all coding agents touching this repository. Keep responses factual and avoid speculative language.

### 1. Communication & Planning

- Always mention assumptions; ask the user to confirm anything ambiguous before editing.
- Follow the required plan/approval workflow when prompted and wait for explicit approval to execute.
- Use UK-English spelling in comments, documentation, and commit messages.

### 2. File Safety

- Do **not** edit `.env` or other environment files; only reference `.env.example`.
- Delete files only when you created them or the user explicitly instructs you to remove older assets.
- Never run destructive git commands (`git reset --hard`, `git checkout --`, `git restore`, `rm -rf .git`) unless the user provides written approval in this thread.
- Treat rename automation as a one-time setup; never re-run it on an established project.

### 3. Collaboration Etiquette

- If another agent has edited a file, read their changes and build on them-do not revert or overwrite.
- Coordinate before touching large refactors that might conflict with ongoing work.
- Keep diffs minimal and reviewable; use targeted edits rather than rewriting whole files.

### 4. Git & Commits

- Check `git status` before staging and before committing.
- Keep commits atomic and list paths explicitly, e.g. `git commit -m "feat: add CI" -- path/to/file`.
- For new files: `git restore --staged :/ && git add <paths> && git commit -m "<msg>" -- <paths>`.
- Quote any paths containing brackets/parentheses when staging to avoid globbing.
- Never amend existing commits unless the user instructs you to.
- Don't plaster all commits and git issues with "Made with Cursor", "Cursor helped me with this", "AI did everything" or anything similar.

### 5. Pre-flight Checklist

1. Read the task, confirm assumptions, and outline the approach.
2. Inspect the relevant files (include imports/configs for context).
3. Run the documented commands after code changes:
   `make install`, `make lint`, `make format`, `make test`, `make precommit`, `make check`.
4. Summarise edits, mention tests, and flag follow-up work in the final response.
