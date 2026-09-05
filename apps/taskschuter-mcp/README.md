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
