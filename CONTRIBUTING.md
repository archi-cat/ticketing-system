# Contributing

This document describes the development workflow for this project.

## Branch strategy

- `main` is protected — no direct pushes
- All changes go through pull requests
- Branch naming: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` followed by a short slug (e.g. `feat/reservation-expiry-sweeper`)

## Pull request workflow

1. Create a branch from `main`:
```bash
   git checkout main
   git pull
   git checkout -b feat/your-change
```
2. Make your changes and commit using [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat: add reservation expiry endpoint`
   - `fix: handle expired reservations correctly`
   - `chore: update Terraform AKS module to v4.5`
   - `docs: add ADR for distributed locking strategy`
3. Push and open a pull request
4. Ensure all CI checks pass
5. Request review (or self-merge if working solo)
6. Merge using **Squash and merge** to keep `main` linear

## Commit message format

Follow Conventional Commits:

```
<type>(<optional scope>): <subject>

<optional body>

<optional footer>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`, `ci`, `build`

## Architectural changes

Any change that affects the overall architecture must be accompanied by an ADR (Architectural Decision Record) in `docs/decisions/`. See the existing ADRs for the format.

## Local development

See the README in each service directory:

- [app/api/README.md](app/api/README.md)
- [app/worker/README.md](app/worker/README.md)
- [app/scheduler/README.md](app/scheduler/README.md)

## Pre-commit checks

Before opening a PR, run locally:

```bash
# Lint and format
ruff check .
ruff format .

# Run tests
pytest

# Validate Terraform
cd terraform/environments/uksouth-primary
terraform fmt -check
terraform validate
```