# Studio deployment templates for the `home` box

One folder per studio the shared agent-service on `home` serves
(`studios/home.yml`). Each `deployment.json` names the engine, the studio's
`applicationId` and its public URL, so one agent-service can host several studio
types, each at its own address.

`{fqdn}` stands for the box's tailnet name, which is kept out of this public
repo. `studios/render-home-deployments.sh` fills it in from `TAILNET_FQDN` and
writes the result to `$ENV_DIR/home-deployments` (next to the gitignored env
files), which is what the agent-service mounts.

To add a studio: add a folder here, add its web service to `studios/home.yml`,
its port to `tailscale/serve.sh`, its origin to `CORS_ORIGINS` and
`PANEL_FRAME_ANCESTORS`, and its engine to `PROFILES`; then re-render.
