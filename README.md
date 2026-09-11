# Shadow Haven Hosting

Docker images and Pterodactyl / Pelican eggs for the games Shadow Haven Hosting offers.

| Game | Image | Egg | Notes |
|---|---|---|---|
| WARDOGS | `ghcr.io/<owner>/wardogs:latest` (built by [build-wardogs.yml](.github/workflows/build-wardogs.yml)) | [eggs/wardogs/egg-wardogs.json](eggs/wardogs/egg-wardogs.json) | Needs Bulkhead community-provider credentials — see [wardogs/README.md](wardogs/README.md) |

## Layout

```
wardogs/                 Dockerfile + entrypoint for the WARDOGS image (build context)
eggs/wardogs/            importable egg JSON
.github/workflows/       CI that builds and pushes images to GitHub Container Registry
```

## First-time setup

1. Create the GitHub repo and push `main`:
   ```bash
   git remote add origin git@github.com:<owner>/shadow-haven-hosting.git
   git push -u origin main
   ```
2. The workflow runs on push and publishes `ghcr.io/<owner>/wardogs:latest`
   (`<owner>` = your GitHub user/org, lower-cased).
3. On GitHub → Packages → `wardogs` → Package settings → change visibility to **Public**
   so Wings nodes can pull without a login (the image contains no game files, only the runtime).
   Keep it private instead and add the registry credentials to each node's `config.yml`
   under `docker.registries` if you prefer.
4. Edit `eggs/wardogs/egg-wardogs.json` → `docker_images` to match the published name, then
   import the egg in the panel (Admin → Nests → Import Egg).
