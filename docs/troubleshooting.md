# Troubleshooting

Always start with:

```bash
iphone-photos diagnostics
```

The output contains no passwords or keys and can be shared.

## The bar icon is dimmed

Immich is not running. Run `iphone-photos server start` or use "Start Immich"
in the panel. After a reboot Immich only comes back by itself if
`docker.service` is enabled:

```bash
systemctl is-enabled docker.service
sudo systemctl enable --now docker.service
```

## The bar shows a warning triangle

The port is open but the API does not answer, or Immich is in maintenance
mode. Right after a start that is normal. Otherwise:

```bash
iphone-photos server logs
```

## The iPhone cannot find the server

1. Is the iPhone on the same Wi-Fi? Guest networks often isolate devices.
2. Is the address still right? `iphone-photos address`
3. Does the server answer on the PC? `curl http://localhost:2283/api/server/ping`
4. Firewall: Omarchy's ufw rules for Docker let private networks through.
   Check with `sudo ufw status verbose` and
   `grep -A12 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules`
5. Over Tailscale or mobile data the server is deliberately unreachable.

## The panel shows no photo counts

No API key is stored, or it lacks permissions. Without `server.statistics`
(administrators only) the panel shows the counts of your own account, without
`queue.read` no jobs.

```bash
iphone-photos api-key status
iphone-photos api-key set
```

## Password prompt on start and stop

Intended: Omarchy gives the user no direct Docker access. Monitoring in the
panel works without a prompt.

## Storage location "not mounted"

The disk for `UPLOAD_LOCATION` is missing. Stop Immich, mount the disk, start
again. Do not let it keep running: uploads would land on the system disk.

## The plugin does not appear

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.badr-emil.iphone-photos
omarchy plugin list | grep iphone-photos
omarchy-shell shell rescanPlugins
quickshell log -p /usr/share/omarchy/shell | grep iphone-photos
```

## The image download aborts

`net/http: timeout` during the first start is a network problem reaching the
registry `ghcr.io`. Start again; layers already downloaded are kept.
