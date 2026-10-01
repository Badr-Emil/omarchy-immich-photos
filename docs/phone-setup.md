# Connecting your phone

The Immich app on the phone does the transfer. The plugin only shows the
address and the state of the server. It works the same way for iPhones and
Android phones, and several phones can back up to the same server.

## Steps

1. On the PC, open `http://localhost:2283` and create an account if there is
   none yet.
2. Install the Immich app on the phone: App Store on an iPhone, Google Play or
   F-Droid on Android.
3. Put the phone on the same Wi-Fi as the PC.
4. Enter the server address in the app. It is shown in the panel under
   "Connect phone" (`http://192.168.x.x:2283`), also as a QR code. The QR code
   contains the address and nothing else.
5. Log in with the Immich account.
6. Open Backup → choose albums → turn Backup on. Allow access to all photos
   the first time.

## What the phone allows

Both iOS and Android decide when an app may work in the background. The Immich
app registers for it, but nothing guarantees immediate or gapless transfer.

- Reliable: open the app and leave it open, especially for the first large run.
- iPhone: turn on background backup in the app and allow Background App
  Refresh for Immich in the iOS settings. Low Power Mode pauses background work.
- Android: turn on background backup in the app and exempt Immich from battery
  optimization, otherwise the system stops it after a while.

The panel therefore never says "the phone is syncing". It shows when the app
last talked to the server (accurate to about an hour, because Immich refreshes
the timestamp at most hourly) and how many jobs the server still has to
process.

## Checking that a photo arrived

```bash
immich-photos status
sudo find ~/Pictures/Immich/upload ~/Pictures/Immich/library -type f -mmin -10
```

Immich stores originals under `upload/`, or under `library/` when the storage
template is enabled. The files belong to root because the container runs as
root; every user can read them, only Immich should change them.

## Away from home

Outside the home network the server is deliberately unreachable. The app
uploads once the phone is back on the Wi-Fi. Remote access through a VPN is a
later topic and is never set up automatically.

## The address changes

The PC gets its address from DHCP. If it changes, the app no longer finds the
server. Remedy: reserve a fixed address for the PC in the router.
