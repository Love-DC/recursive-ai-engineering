import { SignJWT, importPKCS8 } from "npm:jose@5.9.6";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "GET, OPTIONS",
  "content-type": "application/json; charset=utf-8",
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function publishableKey(): string {
  const raw = requiredEnv("SUPABASE_PUBLISHABLE_KEYS");
  const parsed = JSON.parse(raw);
  const key = parsed.default ?? Object.values(parsed)[0];
  if (typeof key !== "string" || !key) throw new Error("No Supabase publishable key configured");
  return key;
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const response = await fetch(`${requiredEnv("SUPABASE_URL")}/auth/v1/user`, {
    headers: { apikey: publishableKey(), authorization: `Bearer ${match[1]}` },
  });
  if (!response.ok) return null;
  const user = await response.json();
  return user?.id ? { user, accessToken: match[1] } : null;
}

async function ownedProject(accessToken: string, repo: string) {
  const url = new URL(`${requiredEnv("SUPABASE_URL")}/rest/v1/projects`);
  url.searchParams.set("select", "id,github_repo,name");
  url.searchParams.set("github_repo", `eq.${repo}`);
  url.searchParams.set("status", "eq.active");
  const response = await fetch(url, {
    headers: {
      apikey: publishableKey(),
      authorization: `Bearer ${accessToken}`,
    },
  });
  if (!response.ok) throw new Error("Project authorization lookup failed");
  const rows = await response.json();
  return Array.isArray(rows) ? rows[0] ?? null : null;
}

async function installationToken(): Promise<string> {
  const appId = requiredEnv("GITHUB_APP_ID");
  const installationId = requiredEnv("GITHUB_APP_INSTALLATION_ID");
  const pem = requiredEnv("GITHUB_APP_PRIVATE_KEY").replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(appId)
    .setIssuedAt(now - 30)
    .setExpirationTime(now + 8 * 60)
    .sign(key);

  const response = await fetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${jwt}`,
        "x-github-api-version": "2022-11-28",
      },
    },
  );
  if (!response.ok) {
    // Never include response bodies: GitHub error payloads are not needed by callers.
    throw new Error(`GitHub App token exchange failed (HTTP ${response.status})`);
  }
  const data = await response.json();
  if (typeof data.token !== "string") throw new Error("GitHub token exchange returned no token");
  return data.token;
}

async function githubGet(path: string, token: string) {
  const response = await fetch(`https://api.github.com${path}`, {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub API request failed (HTTP ${response.status})`);
  }
  return await response.json();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return json(405, { error: "method_not_allowed" });

  try {
    const auth = await authenticate(req);
    if (!auth) return json(401, { error: "unauthorized" });

    const url = new URL(req.url);
    if (url.pathname === "/github-app-gateway/health") {
      return json(200, { ok: true, authenticated: true });
    }

    if (url.pathname === "/github-app-gateway/installation/repositories") {
      const token = await installationToken();
      const data = await githubGet("/installation/repositories?per_page=100", token);
      const projectsUrl = new URL(`${requiredEnv("SUPABASE_URL")}/rest/v1/projects`);
      projectsUrl.searchParams.set("select", "github_repo,name");
      projectsUrl.searchParams.set("status", "eq.active");
      const projectResponse = await fetch(projectsUrl, {
        headers: {
          apikey: publishableKey(),
          authorization: `Bearer ${auth.accessToken}`,
        },
      });
      if (!projectResponse.ok) return json(403, { error: "project_scope_unavailable" });
      const projects = await projectResponse.json();
      const registered = new Set(
        (Array.isArray(projects) ? projects : [])
          .map((p: { github_repo?: string }) => p.github_repo)
          .filter((name: unknown): name is string => typeof name === "string"),
      );
      const repositories = (data.repositories ?? [])
        .filter((r: { full_name?: string }) => registered.has(r.full_name))
        .map((r: { id: number; full_name: string; private: boolean; default_branch: string }) => ({
          id: r.id,
          full_name: r.full_name,
          private: r.private,
          default_branch: r.default_branch,
        }));
      return json(200, { total_registered_repositories: repositories.length, repositories });
    }

    const match = url.pathname.match(/^\/github-app-gateway\/repos\/([^/]+\/[^/]+)(?:\/(metadata|contents|branches))?$/);
    if (!match) return json(404, { error: "not_found" });
    const repo = decodeURIComponent(match[1]).toLowerCase();
    const project = await ownedProject(auth.accessToken, repo);
    if (!project) return json(403, { error: "repository_not_authorized" });

    const suffix = match[2] ?? "metadata";
    const token = await installationToken();
    const encodedRepo = repo.split("/").map(encodeURIComponent).join("/");
    let result: unknown;
    if (suffix === "metadata") {
      result = await githubGet(`/repos/${encodedRepo}`, token);
    } else if (suffix === "branches") {
      result = await githubGet(`/repos/${encodedRepo}/branches?per_page=100`, token);
    } else {
      const path = url.searchParams.get("path");
      if (!path || path.startsWith("/") || path.split("/").some((part) => part === "..")) {
        return json(400, { error: "invalid_contents_path" });
      }
      result = await githubGet(`/repos/${encodedRepo}/contents/${path.split("/").map(encodeURIComponent).join("/")}`, token);
    }
    return json(200, { project_id: project.id, repository: repo, data: result });
  } catch (error) {
    // Do not log exception objects: SDK/network errors can contain request details.
    console.error(error instanceof Error ? error.message : "gateway_error");
    return json(500, { error: "github_gateway_error" });
  }
});
