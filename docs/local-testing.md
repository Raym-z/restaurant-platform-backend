# Local Testing

## 1. Prerequisites

- Node 24 (see `.nvmrc`)
- npm 11+
- Docker Desktop (Windows) or Docker Engine (Linux/macOS)
- Pinned Supabase CLI (installed as a dev dependency; no global install required)

On Windows, Docker Desktop must use the **WSL 2 backend**. Virtualization must be
enabled in BIOS/UEFI.

## 2. Windows Docker setup

1. Install Docker Desktop for Windows.
2. Open Docker Desktop → Settings → General → enable **Use the WSL 2 based engine**.
3. Apply and restart Docker Desktop.
4. Wait until the status bar shows **Engine running**.
5. Open a new PowerShell window and run:

```powershell
docker --version
docker info --format "{{.ServerVersion}}"
npm run doctor
```

If `docker info` reports a missing `dockerDesktopLinuxEngine` pipe, Docker Desktop
is installed but its engine is not running. Start Docker Desktop and wait for
**Engine running**.

If WSL reports a problem:

```powershell
wsl --update
wsl --status
```

If `wsl --status` says WSL 2 is **not supported with your current machine
configuration**:

1. Enable the **Virtual Machine Platform** Windows optional feature.
2. Ensure CPU virtualization is enabled in BIOS/UEFI.
3. Run `wsl --install --no-distribution` from an elevated PowerShell.
4. Restart Windows, then start Docker Desktop again.

Then restart Docker Desktop. `npm run doctor` reports this condition explicitly.

## 3. Commands

```powershell
npm install              # install pinned test tooling
npm run doctor           # diagnose Docker, Supabase, ports, config
npm run test:static      # no Docker needed
npm run test:db          # local stack + migrations + pgTAP
npm run test:integration # Node integration/concurrency
npm run test:edge        # Edge Functions, skipped until Agent 2 adds them
npm run test:all         # complete local suite
```

`npm run test:all` is the single documented command for the full local suite. It
stops with remediation if Docker is unavailable.

## 4. What each command does

| Command | Docker | Behavior |
|---|---|---|
| `test:static` | No | Script syntax, migration governance, secret scan, blocker register, RLS manifest structure, typecheck, contract unit tests |
| `test:db` | Yes | Starts local Supabase, `db reset --no-seed`, applies test helpers, runs pgTAP, lints functions, checks RLS manifest against the DB |
| `test:db:fast` | Yes | Same as `test:db` without resetting migrations |
| `test:integration` | Yes | Requires a running local stack; runs Vitest integration/concurrency tests |
| `test:edge` | Yes + Deno | Skips cleanly while `supabase/functions/` is absent |
| `test:all` | Yes | Doctor → static → database → integration → edge |

## 5. Test database rules

- Tests always use `supabase db reset --no-seed`.
- Development seed data is not a test dependency.
- Test helpers are recreated from `tests/sql/` on every prepare and are never
  migrations.
- Local ports: API `54321`, DB `54322`, shadow `54320`.
- All endpoints must be loopback; the guard rejects unknown hosts and never falls
  back to remote credentials.

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `dockerDesktopLinuxEngine` pipe missing | Start Docker Desktop and wait for **Engine running** |
| Docker context is not `desktop-linux` | `docker context use desktop-linux` |
| Port 54322 already in use | `Get-NetTCPConnection -LocalPort 54322`; stop the owner or change the local DB port |
| `supabase/config.toml` missing | Agent 1 owns it; static checks still work, database tests stay blocked |
| Supabase stack not running | `npm run test:db` or `npx supabase start` |
| WSL errors | `wsl --update`, restart Docker Desktop |
| Deno missing (edge) | Install Deno or skip `test:edge` until Agent 2 adds functions |

## 7. Static-only workflow

Useful while Agent 1 builds the schema:

```powershell
npm run test:static
```

This validates tooling, migration governance, secrets, blocked rules, manifest
structure, TypeScript, and contract unit tests without Docker.
