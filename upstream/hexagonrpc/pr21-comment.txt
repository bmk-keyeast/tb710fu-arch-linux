**Post as a comment on:** https://github.com/linux-msm/hexagonrpc/pull/21

---

Another SM8650 data point, from a Lenovo TB710FU (Xiaoxin Pad Pro GT). On this tablet the sensor PD needs more than `fwrite` and `fremove`, so I implemented real writes to get the sensors up:

- It opens `/mnt/vendor/persist/sensors/registry/registry/DIR` for writing during init.
- It updates registry files by writing `fstempfile` and renaming it over the target.
- It also keeps `sns_reg_version` and `parsed_file_list.csv` in `persist/sensors/registry/`, so that whole directory has to be mapped.
- `fwrite` carries its data inline, so messages exceed the 256 byte receive buffer in `listener.c`.

The methods it uses are `fwrite` (5), `fsync` (23), `fremove` (24), `mkdir` (29), `ftrunc` (32) and `frename` (33). The `mkdir` path argument also has to be a `HRPC_ARG_BLOB_SEQ`.

With the attached patch on top of `da7a374`, the registry sensor comes up, SSC lists the sensors, and iio-sensor-proxy delivers accelerometer and ambient light readings. It has been running on this tablet since November 2026. I did not test this tablet with the stubs from this PR.

This patch is not meant for merging as it is. It limits writes to paths below `/mnt/vendor/persist` and `/persist`, but it writes into a directory under the read-only prefix, which goes against what @lumag suggested above. I can rework it so that writes go to a state directory such as `/var/lib/hexagonrpcd`, and rebase it on this PR or send it as a follow-up. Which would you prefer?

The patch and this comment were prepared with an AI coding assistant (Claude Opus 5.5).
