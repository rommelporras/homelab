# Code Reviewer Agent Memory

## chezmoi Conventions
- `private_dot_` prefix: 0700 for directories, 0600 for files (NOT just 0600)
- `executable_` prefix: sets 0755 on files
- `private_` on parent dir does NOT cascade to children -- children get their own permissions
- `run_once_before_` scripts run before chezmoi creates any managed files
- chezmoi handles symlink-to-file replacement correctly during `chezmoi apply`
- `.chezmoiignore` supports Go template conditionals for per-environment exclusions

## Dotfiles Repo (~/personal/dotfiles)
- Claude Code config lives in `home/private_dot_claude/`
- `CLAUDE.md.tmpl` is the only templated file in the Claude config
- All other Claude files (settings.json, hooks, agents, skills) are plain copies
- `.chezmoiignore` must cover ALL runtime files in `~/.claude/` to prevent chezmoi from deleting them
- `aurora` and `distrobox-sandbox` environments exclude entire `.claude/` directory
