**Title:** SSC: start sensors claimed before the driver opened, and do not crash on a NULL GError

**Target:** `hadess/iio-sensor-proxy`, branch `master` (based on `ca0d5b08`)

---

Two fixes for the SSC backend, found on a Lenovo TB710FU (SM8650) running KDE Plasma.

### Start sensors that were claimed while their driver was opening

SSC sensors open asynchronously, because libssc discovers them over QRTR. A client can claim a sensor as soon as the proxy is on the bus, which may be before `DEVICE_FOR_TYPE()` is set. The claim is recorded, but polling is never started, and later claims only add clients.

KWin hit this in a window of about 9 ms, and auto-rotation stayed off until the proxy was restarted. The hotplug path already handles this case, so this does the same after the initial `driver_open()`.

This is separate from !414. That MR covers clients that never claim because they do not see the sensor yet. This one covers a client that did claim, too early.

### Do not dereference a NULL GError

libssc can report a failure without setting the `GError`. Logging `error->message` then crashes the proxy with a segmentation fault, which happened several times per boot on this tablet. The log now falls back to a generic message. libssc should probably also set the error, but the proxy should not crash either way.

### Testing

Both changes have been running on the TB710FU since November 2026 with KWin as the client. Auto-rotation and the ambient light sensor work after boot and after suspend to idle, and the crash no longer occurs.

The patches and this description were prepared with an AI coding assistant (Claude Opus 5.5).
