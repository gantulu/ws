# Workspace (WS)

This repository is the working area for the ASRI Collection Duitku V1.2 remediation plan and sandbox verification artifacts.

## Scope

- Security remediation design for Supabase database policies and privileged functions
- Duitku payment integrity and callback idempotency design
- Custom-auth hardening requirements (without Supabase Auth)
- Sandbox end-to-end test plan and acceptance criteria

## Safety boundaries

- No production database or Edge Function changes are made from this repository.
- No credentials, API keys, or secret values may be committed.
- Implement against an explicitly confirmed Supabase project and a sandbox environment only.
- Preserve legacy tables until their consumers have been mapped.

See [`docs/duitku-v1.2-remediation.md`](docs/duitku-v1.2-remediation.md) for the detailed plan.