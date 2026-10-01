# Studio deployment templates for the `home` box

One folder per studio the shared agent-service on `home` serves
(`studios/home.yml`). Each `deployment.json` names the engine, the studio's
`applicationId` and its public URL, so one agent-service can host several studio
types, each at its own address.

`{domain}` stands for the studios' domain (`STUDIOS_DOMAIN` in the gitignored
`studios.env`), which is kept out of this public repo; each studio lives at a
name under it (home., witness.; the domain itself is e.g.
studio.example.com), served by `caddy/`.
`studios/render-home-deployments.sh` fills it in and writes the result to
`$ENV_DIR/home-deployments`, which is what the agent-service mounts.

To add a studio: add a folder here, add its web service to `studios/home.yml`,
its name to `caddy/Caddyfile`, its origin to `CORS_ORIGINS` and
`PANEL_FRAME_ANCESTORS`, and its engine to `PROFILES`; then re-render.
