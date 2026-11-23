import { SignJWT, importPKCS8 } from "npm:jose@5.9.6";

const headers = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "GET, OPTIONS",
  "content-type": "application/json; charset=utf-8",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers });

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing environment variable: " + name);
  return value;
}
function publishableKey(): string {
  const keys = JSON.parse(env("SUPABASE_PUBLISHABLE_KEYS"));
  const key = keys.default ?? Object.values(keys)[0];
  if (typeof key !== "string" || !key) throw new Error("No publishable key configured");
  return key;
}
async function authenticate(req: Request) {
  const authorization = req.headers.get("authorization") ?? "";
  const accessToken = authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice(7).trim() : "";
  if (!accessToken) return null;
  const response = await fetch(env("SUPABASE_URL") + "/auth/v1/user", {
    headers: { apikey: publishableKey(), authorization: "Bearer " + accessToken },
  });
  if (!response.ok) return null;
  const user = await response.json();
  return user?.id ? { user, accessToken } : null;
}
async function projectForUser(accessToken: string, repo: string) {
  const url = new URL(env("SUPABASE_URL") + "/rest/v1/projects");
  url.searchParams.set("select", "id,github_repo,name");
  url.searchParams.set("github_repo", "eq." + repo);
  url.searchParams.set("status", "eq.active");
  const response = await fetch(url, {
    headers: { apikey: publishableKey(), authorization: "Bearer " + accessToken },
  });
  if (!response.ok) throw new Error("Project authorization lookup failed");
  const rows = await response.json();
  return Array.isArray(rows) ? rows[0] ?? null : null;
}
async function createInstallationToken(): Promise<string> {
  const pem = env("GITHUB_APP_PRIVATE_KEY").replaceAll("\\n", "\n");
  const key = await importPKCS8(pem, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(env("GITHUB_APP_ID"))
    .setIssuedAt(now - 30)
    .setExpirationTime(now + 8 * 60)
    .sign(key);
  const response = await fetch(
    "https://api.github.com/app/installations/" + env("GITHUB_APP_INSTALLATION_ID") + "/access_tokens",
    { method: "POST", headers: {
      accept: "application/vnd.github+json",
      authorization: "Bearer " + jwt,
      "x-github-api-version": "2022-11-28",
    }},
  );
  if (!response.ok) throw new Error("GitHub App token exchange failed (HTTP " + response.status + ")");
  const data = await response.json();
  if (typeof data.token !== "string") throw new Error("GitHub returned no installation token");
  return data.token;
}
async function githubGet(path: string, token: string) {
  const response = await fetch("https://api.github.com" + path, { headers: {
    accept: "application/vnd.github+json",
    authorization: "Bearer " + token,
    "x-github-api-version": "2022-11-28",
  }});
  if (!response.ok) throw new Error("GitHub API request failed (HTTP " + response.status + ")");
  return await response.json();
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "GET") return json(405, { error: "method_not_allowed" });
  try {
    const auth = await authenticate(req);
    if (!auth) return json(401, { error: "unauthorized" });
    const url = new URL(req.url);
    const prefix = "/github-app-gateway/";
    if (!url.pathname.startsWith(prefix)) return json(404, { error: "not_found" });
    const route = url.pathname.slice(prefix.length);
    if (route === "health") return json(200, { ok: true, authenticated: true });
    if (route === "installation/repositories") {
      const token = await createInstallationToken();
      const data = await githubGet("/installation/repositories?per_page=100", token);
      const projectsUrl = new URL(env("SUPABASE_URL") + "/rest/v1/projects");
      projectsUrl.searchParams.set("select", "github_repo");
      projectsUrl.searchParams.set("status", "eq.active");
      const projectResponse = await fetch(projectsUrl, {
        headers: { apikey: publishableKey(), authorization: "Bearer " + auth.accessToken },
      });
      if (!projectResponse.ok) return json(403, { error: "project_scope_unavailable" });
      const projects = await projectResponse.json();
      const registered = new Set((Array.isArray(projects) ? projects : [])
        .map((p: { github_repo?: string }) => p.github_repo));
      const repositories = (data.repositories ?? [])
        .filter((r: { full_name?: string }) => registered.has(r.full_name))
        .map((r: { id: number; full_name: string; private: boolean; default_branch: string }) => ({
          id: r.id, full_name: r.full_name, private: r.private, default_branch: r.default_branch,
        }));
      return json(200, { total_registered_repositories: repositories.length, repositories });
    }
    const parts = route.split("/");
    if (parts.length < 3 || parts[0] !== "repos") return json(404, { error: "not_found" });
    const repo = (parts[1] + "/" + parts[2]).toLowerCase();
    const suffix = parts[3] ?? "metadata";
    if (parts.length > 4 || !["metadata", "contents", "branches"].includes(suffix)) {
      return json(404, { error: "not_found" });
    }
    const project = await projectForUser(auth.accessToken, repo);
    if (!project) return json(403, { error: "repository_not_authorized" });
    const token = await createInstallationToken();
    const encodedRepo = repo.split("/").map(encodeURIComponent).join("/");
    let data: unknown;
    if (suffix === "metadata") data = await githubGet("/repos/" + encodedRepo, token);
    else if (suffix === "branches") data = await githubGet("/repos/" + encodedRepo + "/branches?per_page=100", token);
    else {
      const path = url.searchParams.get("path");
      if (!path || path.startsWith("/") || path.split("/").some((part) => part === "..")) {
        return json(400, { error: "invalid_contents_path" });
      }
      data = await githubGet("/repos/" + encodedRepo + "/contents/" +
        path.split("/").map(encodeURIComponent).join("/"), token);
    }
    return json(200, { project_id: project.id, repository: repo, data });
  } catch (error) {
    console.error(error instanceof Error ? error.message : "gateway_error");
    return json(500, { error: "github_gateway_error" });
  }
});
