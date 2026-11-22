# Owner Console

Browser-based Owner console for MVP v1.2. It uses Supabase Auth and the project's publishable key; all business reads/writes go through the existing authenticated RPCs.

## Local run

1. Copy `.env.example` to `.env.local`.
2. Set the Supabase URL and **publishable** key from Project Settings → API Keys.
3. Run `npm install`, then `npm run dev`.
4. Sign in using the Owner Auth account already provisioned in Supabase.

Do not enable public sign-up for this Owner-only console. Do not add service_role/secret keys or database passwords to frontend environment variables.

## Included

- Email/password sign-in and sign-out.
- Register a project through `register_project`.
- Register Workers through `register_worker`.\n- Bind an existing Supabase Auth user to a Worker through the Owner-only `bind_worker_identity` RPC; each Worker must use its own Auth user to execute.
- Create implementation Tasks through `create_task`.
- List Workers and Tasks; inspect full Task, Execution, artifact and review context through `get_task`.

## Deploy

Deploy this directory as a Vite project on Vercel or another static host. Set:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Build command: `npm run build`; output directory: `dist`.

## Current boundary

The console does not create Supabase Auth users or run GPT Workers. Create each Worker Auth user through Supabase Auth, then bind that existing user's UUID in the Worker registration/binding dialog. Workers authenticate with their own user session and use the documented RPC protocol. Owner sessions retain administrative override and must not be reused as Worker sessions. Browser sign-in and end-to-end tests with multiple independent Auth users remain release gates.