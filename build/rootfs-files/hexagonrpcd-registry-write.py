#!/usr/bin/env python3
"""Add sensor-registry write support to hexagonrpcd (linux-msm/hexagonrpc da7a374).

The TB710FU ADSP sensor PD writes its registry at init (it opens
/mnt/vendor/persist/sensors/registry/registry/DIR for writing, as on Android where sscrpcd
serves persist read-write). Upstream hexagonrpcd is read-only, so the registry sensor never
comes up and SSC lists no sensors. Writes are allowed only below /mnt/vendor/persist and
/persist, i.e. into the host directory mapped there (P/sensors/registry/).

    python3 hexagonrpcd-registry-write.py <hexagonrpc checkout>   (idempotent)
"""
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]) / "hexagonrpcd"


def edit(rel, old, new):
    p = ROOT / rel
    s = p.read_text()
    if new in s:
        return
    assert s.count(old) == 1, f"{rel}: anchor not found once: {old[:60]!r}"
    p.write_text(s.replace(old, new))


# hexagonfs.h: optional write ops (only the strict host mapping implements them)
edit("hexagonfs.h", "\tint (*seek)(struct hexagonfs_fd *fd, off_t off, int whence);\n};", """\tint (*seek)(struct hexagonfs_fd *fd, off_t off, int whence);
\tint (*openat_write)(struct hexagonfs_fd *dir, const char *segment, int flags,
\t\t\t    struct hexagonfs_fd **out);
\tssize_t (*write)(struct hexagonfs_fd *fd, size_t size, const void *ptr);
\tint (*truncate)(struct hexagonfs_fd *fd, off_t len);
\tint (*unlinkat)(struct hexagonfs_fd *dir, const char *segment);
\tint (*mkdirat)(struct hexagonfs_fd *dir, const char *segment, mode_t mode);
\tint (*renameat)(struct hexagonfs_fd *olddir, const char *oldseg,
\t\t\tstruct hexagonfs_fd *newdir, const char *newseg);
};""")
edit("hexagonfs.h", "ssize_t hexagonfs_read(struct hexagonfs_fd **fds, int fileno, size_t size, void *ptr);\n",
     """ssize_t hexagonfs_read(struct hexagonfs_fd **fds, int fileno, size_t size, void *ptr);
int hexagonfs_open_write(struct hexagonfs_fd **fds, int rootfd, const char *name, int flags);
ssize_t hexagonfs_write(struct hexagonfs_fd **fds, int fileno, size_t size, const void *ptr);
int hexagonfs_ftruncate(struct hexagonfs_fd **fds, int fileno, off_t len);
int hexagonfs_unlink(struct hexagonfs_fd **fds, int rootfd, const char *name);
int hexagonfs_mkdir(struct hexagonfs_fd **fds, int rootfd, const char *name, mode_t mode);
int hexagonfs_rename(struct hexagonfs_fd **fds, int rootfd, const char *oldname,
\t\t     const char *newname);
""")

# hexagonfs.c: resolve the parent directory, then let its ops create/remove the entry
edit("hexagonfs.c", "int hexagonfs_readdir(struct hexagonfs_fd **fds, int fileno, size_t ent_size, char *ent)\n",
     """/* open name's parent directory; *base points at the last segment. Returns its file number. */
static int open_parent(struct hexagonfs_fd **fds, int rootfd, const char *name,
\t\t       const char **base)
{
\tconst char *slash = strrchr(name, '/');
\tchar *parent;
\tint ret;

\tif (slash == NULL || slash[1] == '\\0')
\t\treturn -EINVAL;

\tparent = strndup(name, slash - name + 1);
\tif (parent == NULL)
\t\treturn -ENOMEM;

\tret = hexagonfs_openat(fds, rootfd, rootfd, parent);
\tfree(parent);
\t*base = slash + 1;

\treturn ret;
}

int hexagonfs_open_write(struct hexagonfs_fd **fds, int rootfd, const char *name, int flags)
{
\tstruct hexagonfs_fd *dir, *fd;
\tconst char *base;
\tint dirno, ret;

\tdirno = open_parent(fds, rootfd, name, &base);
\tif (dirno < 0)
\t\treturn dirno;

\tdir = fds[dirno];
\tif (dir->ops->openat_write == NULL) {
\t\thexagonfs_close(fds, dirno);
\t\treturn -EROFS;
\t}

\t/* the directory lives on as the new file's (unassigned) parent */
\tfds[dirno] = NULL;
\tdir->is_assigned = false;

\tret = dir->ops->openat_write(dir, base, flags, &fd);
\tif (ret) {
\t\tdestroy_file_descriptor(dir);
\t\treturn ret;
\t}

\tret = allocate_file_number(fds, fd);
\tif (ret < 0)
\t\tdestroy_file_descriptor(fd);

\treturn ret;
}

ssize_t hexagonfs_write(struct hexagonfs_fd **fds, int fileno, size_t size, const void *ptr)
{
\tstruct hexagonfs_fd *fd;

\tif (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
\t\treturn -EBADF;

\tfd = fds[fileno];
\tif (fd == NULL)
\t\treturn -EBADF;

\tif (fd->ops->write == NULL)
\t\treturn -EROFS;

\treturn fd->ops->write(fd, size, ptr);
}

int hexagonfs_ftruncate(struct hexagonfs_fd **fds, int fileno, off_t len)
{
\tstruct hexagonfs_fd *fd;

\tif (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
\t\treturn -EBADF;

\tfd = fds[fileno];
\tif (fd == NULL)
\t\treturn -EBADF;

\tif (fd->ops->truncate == NULL)
\t\treturn -EROFS;

\treturn fd->ops->truncate(fd, len);
}

int hexagonfs_unlink(struct hexagonfs_fd **fds, int rootfd, const char *name)
{
\tconst char *base;
\tint dirno, ret;

\tdirno = open_parent(fds, rootfd, name, &base);
\tif (dirno < 0)
\t\treturn dirno;

\tif (fds[dirno]->ops->unlinkat == NULL)
\t\tret = -EROFS;
\telse
\t\tret = fds[dirno]->ops->unlinkat(fds[dirno], base);

\thexagonfs_close(fds, dirno);
\treturn ret;
}

int hexagonfs_mkdir(struct hexagonfs_fd **fds, int rootfd, const char *name, mode_t mode)
{
\tconst char *base;
\tint dirno, ret;

\tdirno = open_parent(fds, rootfd, name, &base);
\tif (dirno < 0)
\t\treturn dirno;

\tif (fds[dirno]->ops->mkdirat == NULL)
\t\tret = -EROFS;
\telse
\t\tret = fds[dirno]->ops->mkdirat(fds[dirno], base, mode);

\thexagonfs_close(fds, dirno);
\treturn ret;
}

/* both names in host-mapped directories (in practice the registry dir) */
int hexagonfs_rename(struct hexagonfs_fd **fds, int rootfd, const char *oldname,
\t\t     const char *newname)
{
\tconst char *oldbase, *newbase;
\tint olddir, newdir, ret;

\tolddir = open_parent(fds, rootfd, oldname, &oldbase);
\tif (olddir < 0)
\t\treturn olddir;

\tnewdir = open_parent(fds, rootfd, newname, &newbase);
\tif (newdir < 0) {
\t\thexagonfs_close(fds, olddir);
\t\treturn newdir;
\t}

\tif (fds[olddir]->ops->renameat == NULL || fds[olddir]->ops != fds[newdir]->ops)
\t\tret = -EROFS;
\telse
\t\tret = fds[olddir]->ops->renameat(fds[olddir], oldbase, fds[newdir], newbase);

\thexagonfs_close(fds, newdir);
\thexagonfs_close(fds, olddir);
\treturn ret;
}

int hexagonfs_readdir(struct hexagonfs_fd **fds, int fileno, size_t ent_size, char *ent)
""")

# listener.c: fwrite brings its data inline, so messages exceed the 256 B receive buffer
# ("Large (>256B) input buffers aren't implemented" and hexagonrpcd exits). Registry files
# are small: receive up to 64 KiB instead.
edit("listener.c", "\tchar inbufs[256];\n", "\tstatic char inbufs[65536];\n")
edit("listener.c", "\t\t\t\t  &inbufs_len, 256, inbufs);\n", "\t\t\t\t  &inbufs_len, sizeof(inbufs), inbufs);\n")
edit("listener.c", """\tif (inbufs_len > 256) {
\t\tfprintf(stderr, "Large (>256B) input buffers aren't implemented\\n");""", """\tif (inbufs_len > sizeof(inbufs)) {
\t\tfprintf(stderr, "Large (>64KiB) input buffers aren't implemented\\n");""")

# hexagonfs_mapped.c: the host side of the write ops (renameat is in stdio.h)
edit("hexagonfs_mapped.c", "#include <fcntl.h>\n", "#include <fcntl.h>\n#include <stdio.h>\n")
edit("hexagonfs_mapped.c", "static ssize_t mapped_read(struct hexagonfs_fd *fd, size_t size, void *out)\n",
     """static int mapped_openat_write(struct hexagonfs_fd *dir, const char *segment, int flags,
\t\t\t       struct hexagonfs_fd **out)
{
\tstruct mapped_ctx *dir_ctx = dir->data;
\tstruct hexagonfs_fd *fd;
\tstruct mapped_ctx *ctx;
\tint ret;

\tctx = malloc(sizeof(struct mapped_ctx));
\tif (ctx == NULL)
\t\treturn -ENOMEM;

\tfd = malloc(sizeof(struct hexagonfs_fd));
\tif (fd == NULL) {
\t\tret = -ENOMEM;
\t\tgoto err;
\t}

\tctx->fd = openat(dir_ctx->fd, segment, flags | O_CLOEXEC, 0644);
\tif (ctx->fd == -1) {
\t\tret = -errno;
\t\tgoto err_free_fd;
\t}

\tctx->dir = NULL;

\tfd->is_assigned = false;
\tfd->up = dir;
\tfd->ops = &hexagonfs_mapped_ops;
\tfd->data = ctx;

\t*out = fd;

\treturn 0;

err_free_fd:
\tfree(fd);
err:
\tfree(ctx);
\treturn ret;
}

static ssize_t mapped_write(struct hexagonfs_fd *fd, size_t size, const void *ptr)
{
\tstruct mapped_ctx *ctx = fd->data;
\tssize_t ret;

\tret = write(ctx->fd, ptr, size);
\tif (ret < 0)
\t\treturn -errno;

\treturn ret;
}

static int mapped_truncate(struct hexagonfs_fd *fd, off_t len)
{
\tstruct mapped_ctx *ctx = fd->data;

\treturn ftruncate(ctx->fd, len) ? -errno : 0;
}

static int mapped_unlinkat(struct hexagonfs_fd *dir, const char *segment)
{
\tstruct mapped_ctx *ctx = dir->data;

\treturn unlinkat(ctx->fd, segment, 0) ? -errno : 0;
}

static int mapped_mkdirat(struct hexagonfs_fd *dir, const char *segment, mode_t mode)
{
\tstruct mapped_ctx *ctx = dir->data;

\tif (mkdirat(ctx->fd, segment, mode & 0777) && errno != EEXIST)
\t\treturn -errno;

\treturn 0;
}

static int mapped_renameat(struct hexagonfs_fd *olddir, const char *oldseg,
\t\t\t   struct hexagonfs_fd *newdir, const char *newseg)
{
\tstruct mapped_ctx *o = olddir->data, *n = newdir->data;

\treturn renameat(o->fd, oldseg, n->fd, newseg) ? -errno : 0;
}

static ssize_t mapped_read(struct hexagonfs_fd *fd, size_t size, void *out)
""")
edit("hexagonfs_mapped.c", """\t.seek = mapped_seek,
\t.stat = mapped_stat,
};

struct hexagonfs_file_ops hexagonfs_mapped_or_empty_ops = {""", """\t.seek = mapped_seek,
\t.stat = mapped_stat,
\t.openat_write = mapped_openat_write,
\t.write = mapped_write,
\t.truncate = mapped_truncate,
\t.unlinkat = mapped_unlinkat,
\t.mkdirat = mapped_mkdirat,
\t.renameat = mapped_renameat,
};

struct hexagonfs_file_ops hexagonfs_mapped_or_empty_ops = {""")

# rpcd_builder.c: the sensor PD keeps more than registry/registry in persist/sensors/registry
# (sns_reg_version, parsed_file_list.csv, fstempfile): map that whole directory, i.e. the
# host tree is P/sensors/persist-registry/{registry/,sns_reg_version,parsed_file_list.csv}
edit("rpcd_builder.c", '#define SENSORS_REGISTRY\t"/sensors/registry/"',
     '#define SENSORS_REGISTRY\t"/sensors/persist-registry/"')
edit("rpcd_builder.c", """\t\t\t\thfs_mkdir("sensors", 1,
\t\t\t\t\thfs_mkdir("registry", 1,
\t\t\t\t\t\thfs_map("registry", sns_reg)
\t\t\t\t\t)
\t\t\t\t)""", """\t\t\t\thfs_mkdir("sensors", 1,
\t\t\t\t\thfs_map("registry", sns_reg)
\t\t\t\t)""")

# interface: method definitions (ids from Qualcomm's apps_std skel)
edit("interface/apps_std.h", "extern struct hrpc_method_def_interp4 apps_std_mkdir_def;\n",
     """extern struct hrpc_method_def_interp4 apps_std_mkdir_def;
extern struct hrpc_method_def_interp4 apps_std_fwrite_def;
extern struct hrpc_method_def_interp4 apps_std_fsync_def;
extern struct hrpc_method_def_interp4 apps_std_fremove_def;
extern struct hrpc_method_def_interp4 apps_std_ftrunc_def;
extern struct hrpc_method_def_interp4 apps_std_frename_def;
""")
edit("interface/apps_std.c", """static struct hrpc_arg_def_interp4 apps_std_mkdir_args[] = {
\t{ HRPC_ARG_BLOB, sizeof(char) },""", """static struct hrpc_arg_def_interp4 apps_std_mkdir_args[] = {
\t{ HRPC_ARG_BLOB_SEQ, sizeof(char) },""")
p = ROOT / "interface/apps_std.c"
s = p.read_text()
if "apps_std_fwrite_def" not in s:
    s += """
static struct hrpc_arg_def_interp4 apps_std_fwrite_args[] = {
\t{ HRPC_ARG_WORD, sizeof(uint32_t) },
\t{ HRPC_ARG_BLOB_SEQ, sizeof(char) },
\t{ HRPC_ARG_OUT_BLOB, sizeof(uint32_t) },
\t{ HRPC_ARG_OUT_BLOB, sizeof(uint32_t) },
};

const struct hrpc_method_def_interp4 apps_std_fwrite_def = {
\t.msg_id = 5,
\t.n_args = HRPC_ARRAY_SIZE(apps_std_fwrite_args),
\t.args = apps_std_fwrite_args,
\t.n_inner_types = 0,
\t.inner_types = NULL,
};

static struct hrpc_arg_def_interp4 apps_std_fsync_args[] = {
\t{ HRPC_ARG_WORD, sizeof(uint32_t) },
};

const struct hrpc_method_def_interp4 apps_std_fsync_def = {
\t.msg_id = 23,
\t.n_args = HRPC_ARRAY_SIZE(apps_std_fsync_args),
\t.args = apps_std_fsync_args,
\t.n_inner_types = 0,
\t.inner_types = NULL,
};

static struct hrpc_arg_def_interp4 apps_std_fremove_args[] = {
\t{ HRPC_ARG_BLOB_SEQ, sizeof(char) },
};

const struct hrpc_method_def_interp4 apps_std_fremove_def = {
\t.msg_id = 24,
\t.n_args = HRPC_ARRAY_SIZE(apps_std_fremove_args),
\t.args = apps_std_fremove_args,
\t.n_inner_types = 0,
\t.inner_types = NULL,
};

static struct hrpc_arg_def_interp4 apps_std_ftrunc_args[] = {
\t{ HRPC_ARG_WORD, sizeof(uint32_t) },
\t{ HRPC_ARG_WORD, sizeof(uint32_t) },
};

const struct hrpc_method_def_interp4 apps_std_ftrunc_def = {
\t.msg_id = 32,
\t.n_args = HRPC_ARRAY_SIZE(apps_std_ftrunc_args),
\t.args = apps_std_ftrunc_args,
\t.n_inner_types = 0,
\t.inner_types = NULL,
};

static struct hrpc_arg_def_interp4 apps_std_frename_args[] = {
\t{ HRPC_ARG_BLOB_SEQ, sizeof(char) },
\t{ HRPC_ARG_BLOB_SEQ, sizeof(char) },
};

const struct hrpc_method_def_interp4 apps_std_frename_def = {
\t.msg_id = 33,
\t.n_args = HRPC_ARRAY_SIZE(apps_std_frename_args),
\t.args = apps_std_frename_args,
\t.n_inner_types = 0,
\t.inner_types = NULL,
};
"""
    p.write_text(s)

# apps_std.c: writable opens below persist, and the new methods
edit("apps_std.c", """\trw_mode = ((const char *) inbufs[4].p)[0];
\tif (rw_mode == 'w' || rw_mode == 'a') {
\t\tfprintf(stderr, "Tried to open %s for writing\\n",
\t\t\t\t(const char *) inbufs[3].p);
\t\treturn AEE_EUNSUPPORTED;
\t}
""", """\trw_mode = ((const char *) inbufs[4].p)[0];
\tif (rw_mode == 'w' || rw_mode == 'a' || strchr(inbufs[4].p, '+')) {
\t\tconst char *name = inbufs[3].p;
\t\tint flags;

\t\tif (!persist_path(name)) {
\t\t\tfprintf(stderr, "Tried to open %s for writing\\n", name);
\t\t\treturn AEE_EUNSUPPORTED;
\t\t}

\t\tflags = strchr(inbufs[4].p, '+') ? O_RDWR : O_WRONLY;
\t\tif (rw_mode == 'w')
\t\t\tflags |= O_CREAT | O_TRUNC;
\t\telse if (rw_mode == 'a')
\t\t\tflags |= O_CREAT | O_APPEND;

\t\tfd = hexagonfs_open_write(ctx->fds, ctx->rootfd, name, flags);
\t\tif (fd < 0) {
\t\t\tfprintf(stderr, "Could not open %s for writing: %s\\n",
\t\t\t\t\tname, strerror(-fd));
\t\t\treturn AEE_EFAILED;
\t\t}

\t\t*out = fd;
\t\treturn 0;
\t}
""")
edit("apps_std.c", "static uint32_t apps_std_fopen_with_env(void *data,\n", """/* the only writable place: the sensor registry under persist (mapped to the host) */
static bool persist_path(const char *name)
{
\treturn !strncmp(name, "/mnt/vendor/persist/", 20) || !strncmp(name, "/persist/", 9);
}

static uint32_t apps_std_fwrite(void *data,
\t\t\t\tconst struct fastrpc_io_buffer *inbufs,
\t\t\t\tstruct fastrpc_io_buffer *outbufs)
{
\tstruct apps_std_ctx *ctx = data;
\tconst struct {
\t\tuint32_t fd;
\t\tuint32_t buf_size;
\t} *first_in = inbufs[0].p;
\tstruct {
\t\tuint32_t written;
\t\tuint32_t is_eof;
\t} *first_out = outbufs[0].p;
\tssize_t ret;

\tret = hexagonfs_write(ctx->fds, first_in->fd, inbufs[1].s, inbufs[1].p);
\tif (ret < 0) {
\t\tfprintf(stderr, "Could not write file: %s\\n", strerror(-ret));
\t\treturn AEE_EFAILED;
\t}

\tfirst_out->written = ret;
\tfirst_out->is_eof = 0;

\treturn 0;
}

/* writes are plain write(2)s; the registry is small, so no fsync either */
static uint32_t apps_std_fsync(void *data,
\t\t\t       const struct fastrpc_io_buffer *inbufs,
\t\t\t       struct fastrpc_io_buffer *outbufs)
{
\treturn 0;
}

static uint32_t apps_std_fremove(void *data,
\t\t\t\t const struct fastrpc_io_buffer *inbufs,
\t\t\t\t struct fastrpc_io_buffer *outbufs)
{
\tstruct apps_std_ctx *ctx = data;
\tconst char *name = inbufs[1].p;
\tint ret;

\tif (inbufs[1].s == 0 || name[inbufs[1].s - 1] != 0)
\t\treturn AEE_EBADPARM;

\tif (!persist_path(name))
\t\treturn AEE_EUNSUPPORTED;

\tret = hexagonfs_unlink(ctx->fds, ctx->rootfd, name);
\tif (ret && ret != -ENOENT) {
\t\tfprintf(stderr, "Could not remove %s: %s\\n", name, strerror(-ret));
\t\treturn AEE_EFAILED;
\t}

\treturn 0;
}

static uint32_t apps_std_mkdir(void *data,
\t\t\t       const struct fastrpc_io_buffer *inbufs,
\t\t\t       struct fastrpc_io_buffer *outbufs)
{
\tstruct apps_std_ctx *ctx = data;
\tconst struct {
\t\tuint32_t name_len;
\t\tuint32_t mode;
\t} *first_in = inbufs[0].p;
\tconst char *name = inbufs[1].p;
\tint ret;

\tif (inbufs[1].s == 0 || name[inbufs[1].s - 1] != 0)
\t\treturn AEE_EBADPARM;

\tif (!persist_path(name))
\t\treturn AEE_EUNSUPPORTED;

\tret = hexagonfs_mkdir(ctx->fds, ctx->rootfd, name, first_in->mode);
\tif (ret) {
\t\tfprintf(stderr, "Could not mkdir %s: %s\\n", name, strerror(-ret));
\t\treturn AEE_EFAILED;
\t}

\treturn 0;
}

static uint32_t apps_std_ftrunc(void *data,
\t\t\t\tconst struct fastrpc_io_buffer *inbufs,
\t\t\t\tstruct fastrpc_io_buffer *outbufs)
{
\tstruct apps_std_ctx *ctx = data;
\tconst struct {
\t\tuint32_t fd;
\t\tuint32_t len;
\t} *first_in = inbufs[0].p;
\tint ret;

\tret = hexagonfs_ftruncate(ctx->fds, first_in->fd, first_in->len);
\tif (ret) {
\t\tfprintf(stderr, "Could not truncate: %s\\n", strerror(-ret));
\t\treturn AEE_EFAILED;
\t}

\treturn 0;
}

/* the registry is updated by writing fstempfile and renaming it over the target */
static uint32_t apps_std_frename(void *data,
\t\t\t\t const struct fastrpc_io_buffer *inbufs,
\t\t\t\t struct fastrpc_io_buffer *outbufs)
{
\tstruct apps_std_ctx *ctx = data;
\tconst char *oldname = inbufs[1].p, *newname = inbufs[2].p;
\tint ret;

\tif (inbufs[1].s == 0 || oldname[inbufs[1].s - 1] != 0
\t || inbufs[2].s == 0 || newname[inbufs[2].s - 1] != 0)
\t\treturn AEE_EBADPARM;

\tif (!persist_path(oldname) || !persist_path(newname))
\t\treturn AEE_EUNSUPPORTED;

\tret = hexagonfs_rename(ctx->fds, ctx->rootfd, oldname, newname);
\tif (ret) {
\t\tfprintf(stderr, "Could not rename %s to %s: %s\\n",
\t\t\t\toldname, newname, strerror(-ret));
\t\treturn AEE_EFAILED;
\t}

\treturn 0;
}

static uint32_t apps_std_fopen_with_env(void *data,
""")
edit("apps_std.c", "#include <errno.h>\n", "#include <errno.h>\n#include <fcntl.h>\n#include <stdbool.h>\n")
p = ROOT / "apps_std.c"
s = p.read_text()
if ".impl = apps_std_fwrite" not in s:
    procs = s[s.index("static const struct fastrpc_function_impl apps_std_procs[] = {"):s.index("const struct fastrpc_interface apps_std_interface")]
    entries = procs.split("\n\t{")[1:]
    assert len(entries) == 32, len(entries)
    null = " .def = NULL, .impl = NULL, },"

    def ent(name):
        return f"\n\t\t.def = &apps_std_{name}_def,\n\t\t.impl = apps_std_{name},\n\t}},"

    for idx, name in ((5, "fwrite"), (23, "fsync"), (24, "fremove"), (29, "mkdir")):
        assert entries[idx].startswith(null), (idx, entries[idx])
        entries[idx] = ent(name) + entries[idx][len(null):]
    entries.append(ent("ftrunc"))
    entries.append(ent("frename") + "\n};\n\n")
    entries[31] = entries[31].replace("\n};\n\n", "")
    new = "static const struct fastrpc_function_impl apps_std_procs[] = {" + "".join("\n\t{" + e for e in entries)
    s = s.replace(procs, new).replace("\t.n_procs = 32,", "\t.n_procs = 34,")
    p.write_text(s)
print("hexagonrpcd: registry writes enabled")
