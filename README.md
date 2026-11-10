# VideoDrop — personal video sharing

A minimal Persian-language personal video upload/download site, designed for the VPS at `185.190.53.142`.

Features: password-protected admin panel, direct unauthenticated share links with 192-bit random IDs, upload progress, storage indicator, deletion, support for HTTP range/resumable downloads, 1.5 GiB disk safety reserve, no third-party database, streaming uploads without duplicate temporary file copies, automatic HTTPS with Caddy using `185-190-53-142.sslip.io`.

## Install (Ubuntu/Debian with Docker Engine + Docker Compose plugin already installed)

Copy and unzip the archive on the server, then:

```bash
cd /root/video_share_site
sudo bash install.sh
```

Your admin password is shown at the first installation. Save it. It is also in `/opt/video-share/.env` (root-only). Open:

https://185-190-53-142.sslip.io

Ports 80 and 443 must be free and allowed by host/provider firewalls. The script will **not** stop or modify other services. If you use Caddy or Nginx already, contact us to integrate into the existing reverse proxy rather than running a second one on ports 80/443.

Uploads are stored in `/opt/video-share/data/videos`, metadata in `/opt/video-share/data/index.json` and are persistent across container recreation. Removing files from the dashboard deletes the video and invalidates its link. To keep files private, share links only with intended recipients; recipients can forward them.

To see the service status:

```bash
cd /opt/video-share && docker compose ps && docker compose logs --tail=50
```

## Security

- HTTPS certificates use Let's Encrypt through Caddy; the hostname is supplied by the external `sslip.io` DNS service (if available).
- Admin login rate limiting, HttpOnly/Secure/SameSite cookie, basic same-origin check for browser requests.
- Public downloads use random unguessable links, not password protection; anybody with a link can download.
- Ensure backups if your videos are important. Disk capacity is *not* exactly 30GB usable: the OS and other services consume space, and the app reserves 1.5 GiB free.
- No account or login for download recipients.

## No Docker yet?

Install Docker Engine and the Compose plugin from the official documentation at https://docs.docker.com/engine/install/ before running the installer. The installer intentionally does not change the VPS system packages or existing services.