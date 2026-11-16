#!/usr/bin/env python3
"""iio-sensor-proxy ca0d5b08: start sensors claimed before their driver opened.

SSC sensors open asynchronously (libssc discovery over QRTR). KWin claims the accelerometer
as soon as the proxy is on the bus, which can be before DEVICE_FOR_TYPE() is set: the claim
is counted but polling never starts, and later claims only add clients. Auto-rotate then
never gets a reading (2026-11-16, 9 ms window). The hotplug path already handles this; do
the same after the initial driver_open().

    python3 iio-sensor-proxy-claim-race.py <iio-sensor-proxy checkout>   (idempotent)
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1]) / "src/iio-sensor-proxy.c"
s = p.read_text()
old = "\t\tDEVICE_FOR_TYPE(i) = sensor_device;\n\t}\n"
new = """\t\tDEVICE_FOR_TYPE(i) = sensor_device;

\t\t/* claimed while the driver was still opening (SSC): start it now */
\t\tif (g_hash_table_size (data->clients[i]) > 0)
\t\t\tdriver_set_polling (sensor_device, TRUE);
\t}
"""
if new not in s:
    assert s.count(old) == 1, "anchor not found once"
    p.write_text(s.replace(old, new))
print("iio-sensor-proxy: early claims start the sensor")
