# TaskSchuter MCP

This manifest set exposes only the MCP HTTP endpoint through a dedicated
Cloudflare named tunnel. It does not create an Ingress or LoadBalancer.

The deployment requires two runtime-only Kubernetes Secrets that are not kept
in Git:

- `taskschuter-mcp-runtime`: `SUPABASE_PUBLISHABLE_KEY` and
  `TASKSCHUTER_ALLOWED_USER_IDS`
- `taskschuter-mcp-tunnel`: `TUNNEL_TOKEN`
- `taskschuter-mcp-ghcr`: a dedicated GitHub token limited to `read:packages`,
  stored as a `kubernetes.io/dockerconfigjson` image-pull Secret

The MCP server accepts a Supabase OAuth access token, verifies it with
Supabase Auth, then applies the owner allow-list before serving a tool call.

The CLI uses a dedicated public OAuth client registered in the production
Supabase project with the exact redirect URI
`https://mcp.takutk.com/device/callback`. Its public client ID is in the
ConfigMap as `TASKSCHUTER_CLI_OAUTH_CLIENT_ID`. Keep the MCP deployment at one
replica while pending device login sessions are held in memory.
