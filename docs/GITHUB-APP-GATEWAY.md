# GitHub App Gateway

RAE uses the Supabase Edge Function `github-app-gateway` as the server-side boundary for its GitHub App installation.

## Credentials

The function reads these Edge Function Secrets at runtime:

- `GITHUB_APP_ID`
- `GITHUB_APP_PRIVATE_KEY`
- `GITHUB_APP_INSTALLATION_ID`

It never returns the App private key, App JWT, or installation access token. Installation tokens are minted per request and remain server-side.

## Authentication and authorization

- Supabase Edge Function JWT verification remains enabled.
- The handler independently validates the caller's Supabase access token with Supabase Auth.
- Repository operations are restricted to active rows in `public.projects` visible to the caller through existing RLS policies.
- The GitHub installation's repository list is intersected with the caller-visible registered project repositories.
- No caller-supplied repository name alone grants access.
- GitHub App credentials are never stored in Postgres tables or returned to clients.

## Initial read API

Base URL: `https://<project-ref>.supabase.co/functions/v1/github-app-gateway`

All requests require `Authorization: Bearer <Supabase user access token>`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/github-app-gateway/health` | Authenticated function health |
| GET | `/github-app-gateway/installation/repositories` | List installed repositories intersected with caller-visible active projects |
| GET | `/github-app-gateway/repos/{owner}/{repo}/metadata` | Repository metadata |
| GET | `/github-app-gateway/repos/{owner}/{repo}/branches` | Branch list |
| GET | `/github-app-gateway/repos/{owner}/{repo}/contents?path=...` | Repository file or directory contents |

The first release is intentionally read-only. Write operations must be added as explicit, schema-validated routes with idempotency and audit records; do not expose a generic GitHub proxy.

## Operational notes

- GitHub App JWTs are RS256, short-lived, and minted from the private key in Edge Function Secrets.
- Installation access tokens are short-lived and are not persisted.
- Error responses intentionally omit upstream response bodies and credentials.
- The App installation can cover all repositories in its selected account, but this gateway only exposes repositories registered to a project and visible to the authenticated caller.
- For another GitHub organization/account, install the same App there and register its installation ID through a controlled configuration change before enabling that installation.

## Verification

After deployment, verify the function is ACTIVE with JWT verification enabled. Then call the authenticated health endpoint and repository-list endpoint using a valid owner session. Never use a private key or installation token as a client credential.
