# Owner Console

Browser-based Owner console for MVP v1.1. It uses Supabase Auth and the project's publishable key; all business reads/writes go through the existing authenticated RPCs.

## Local run

1. Copy `.env.example` to `.env.local`.
2. Set the Supabase URL and **publishable** key from Project Settings → API Keys.
3. Run `npm install`, then `npm run dev`.
4. Sign in using the Owner Auth account already provisioned in Supabase.

Do not enable public sign-up for this Owner-only console. Do not add service_role/secret keys or database passwords to frontend environment variables.

## Included

- Email/password sign-in and sign-out.
- Register a project through `register_project`.
- Register logical Workers through `register_worker`.
- Create implementation Tasks through `create_task`.
- List Workers and Tasks; inspect full Task, Execution, artifact and review context through `get_task`.

## Deploy

Deploy this directory as a Vite project on Vercel or another static host. Set:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Build command: `npm run build`; output directory: `dist`.

## Current boundary

The console does not create Worker credentials or run GPT Workers. Workers authenticate with a valid user session and use the documented RPC protocol. The current database identity model is a single project Owner with logical Worker IDs; it does not cryptographically isolate separate GPT sessions. Do not treat the console as proof of end-to-end acceptance until authenticated workflow and independent-session tests pass.