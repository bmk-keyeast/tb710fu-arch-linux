/* Run AOSP libavb's avb_slot_verify() over partition dump files, the way a locked ABL does.
 *
 *   avbverify DIR SUFFIX TRUSTED_KEY.bin [floor_loc0 floor_loc1 ...]
 *
 * DIR/<partition><suffix>.img holds each partition (e.g. DIR/boot_b.img). The device is locked,
 * the only trusted vbmeta key is TRUSTED_KEY.bin (AVB public key blob), rollback floors default 0.
 * Requested partitions match Qualcomm ABL for a GKI v4 device: boot, dtbo, vendor_boot, init_boot.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "libavb.h"

static const char* dir;
static uint8_t trusted[4096];
static size_t trusted_len;
static uint64_t floors[AVB_MAX_NUMBER_OF_ROLLBACK_INDEX_LOCATIONS];

static int open_part(const char* part) {
  char p[1024];
  snprintf(p, sizeof p, "%s/%s.img", dir, part);
  return open(p, O_RDONLY);
}

static AvbIOResult read_from_partition(AvbOps* ops, const char* part, int64_t off,
                                       size_t n, void* buf, size_t* nread) {
  int fd = open_part(part);
  if (fd < 0) return AVB_IO_RESULT_ERROR_NO_SUCH_PARTITION;
  struct stat st;
  fstat(fd, &st);
  if (off < 0) off += st.st_size;
  ssize_t r = pread(fd, buf, n, off);
  close(fd);
  if (r < 0) return AVB_IO_RESULT_ERROR_IO;
  *nread = (size_t)r;
  return AVB_IO_RESULT_OK;
}

static AvbIOResult get_size_of_partition(AvbOps* ops, const char* part, uint64_t* out) {
  int fd = open_part(part);
  if (fd < 0) return AVB_IO_RESULT_ERROR_NO_SUCH_PARTITION;
  struct stat st;
  fstat(fd, &st);
  close(fd);
  *out = (uint64_t)st.st_size;
  return AVB_IO_RESULT_OK;
}

static AvbIOResult write_to_partition(AvbOps* ops, const char* part, int64_t off, size_t n,
                                      const void* buf) {
  return AVB_IO_RESULT_ERROR_IO;
}

static AvbIOResult validate_vbmeta_public_key(AvbOps* ops, const uint8_t* pk, size_t pk_len,
                                              const uint8_t* md, size_t md_len, bool* ok) {
  *ok = pk_len == trusted_len && memcmp(pk, trusted, pk_len) == 0;
  return AVB_IO_RESULT_OK;
}

static AvbIOResult read_rollback_index(AvbOps* ops, size_t loc, uint64_t* out) {
  *out = loc < AVB_MAX_NUMBER_OF_ROLLBACK_INDEX_LOCATIONS ? floors[loc] : 0;
  return AVB_IO_RESULT_OK;
}

static AvbIOResult write_rollback_index(AvbOps* ops, size_t loc, uint64_t v) {
  return AVB_IO_RESULT_OK;
}

static AvbIOResult read_is_device_unlocked(AvbOps* ops, bool* out) {
  *out = false;
  return AVB_IO_RESULT_OK;
}

static AvbIOResult get_unique_guid_for_partition(AvbOps* ops, const char* part, char* guid,
                                                 size_t size) {
  snprintf(guid, size, "00000000-0000-0000-0000-000000000000");
  return AVB_IO_RESULT_OK;
}

/* Qualcomm ABL GetOsVerAndSecPactchLevel(): os_version/security_patch from the boot chain vbmeta
 * (else vbmeta), falling back to the boot header os_version (offset 0x2c, v3/v4: 0x10); 0 -> refuse. */
static int abl_os_version_check(AvbSlotVerifyData* data) {
  size_t idx = 0, n;
  for (size_t i = 1; i < data->num_vbmeta_images; i++)
    if (strcmp(data->vbmeta_images[i].partition_name, "boot") == 0) idx = i;
  const char* os = avb_property_lookup(data->vbmeta_images[idx].vbmeta_data,
                                       data->vbmeta_images[idx].vbmeta_size,
                                       "com.android.build.boot.os_version", 0, &n);
  const char* spl = avb_property_lookup(data->vbmeta_images[idx].vbmeta_data,
                                        data->vbmeta_images[idx].vbmeta_size,
                                        "com.android.build.boot.security_patch", 0, &n);
  if (os && spl) {
    printf("ABL os_version check: footer os_version=%s security_patch=%s -> OK\n", os, spl);
    return 0;
  }
  for (size_t i = 0; i < data->num_loaded_partitions; i++) {
    AvbPartitionData* p = &data->loaded_partitions[i];
    if (strcmp(p->partition_name, "boot") != 0 || p->data_size < 48) continue;
    uint32_t ver, raw;
    memcpy(&ver, p->data + 40, 4);
    memcpy(&raw, p->data + (ver >= 3 ? 16 : 44), 4);
    printf("ABL os_version check: footer props %s, header v%u os_version=0x%x -> %s\n",
           os ? "partial" : "missing", ver, raw,
           raw ? "OK" : "REFUSED (\"Boot image header OS version == 0\")");
    return raw ? 0 : 1;
  }
  printf("ABL os_version check: boot not loaded -> REFUSED\n");
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: avbverify DIR SUFFIX TRUSTED_KEY.bin [floors...]\n");
    return 2;
  }
  dir = argv[1];
  FILE* f = fopen(argv[3], "rb");
  if (!f) return 2;
  trusted_len = fread(trusted, 1, sizeof trusted, f);
  fclose(f);
  for (int i = 4; i < argc && i - 4 < AVB_MAX_NUMBER_OF_ROLLBACK_INDEX_LOCATIONS; i++)
    floors[i - 4] = strtoull(argv[i], NULL, 0);

  AvbOps ops = {0};
  ops.read_from_partition = read_from_partition;
  ops.write_to_partition = write_to_partition;
  ops.validate_vbmeta_public_key = validate_vbmeta_public_key;
  ops.read_rollback_index = read_rollback_index;
  ops.write_rollback_index = write_rollback_index;
  ops.read_is_device_unlocked = read_is_device_unlocked;
  ops.get_unique_guid_for_partition = get_unique_guid_for_partition;
  ops.get_size_of_partition = get_size_of_partition;

  /* ABL also requests pvmfw when the partition holds an image (PVMFW_BCC builds, HasPvmFw) */
  const char* requested[] = {"boot", "dtbo", "vendor_boot", "init_boot", NULL, NULL};
  char pv[1024];
  snprintf(pv, sizeof pv, "%s/pvmfw%s.img", dir, argv[2]);
  if (access(pv, R_OK) == 0) requested[4] = "pvmfw";
  printf("requested: boot dtbo vendor_boot init_boot%s\n", requested[4] ? " pvmfw" : "");
  AvbSlotVerifyData* data = NULL;
  AvbSlotVerifyResult r = avb_slot_verify(&ops, requested, argv[2], AVB_SLOT_VERIFY_FLAGS_NONE,
                                          AVB_HASHTREE_ERROR_MODE_RESTART_AND_INVALIDATE, &data);
  int abl_ok = r == AVB_SLOT_VERIFY_RESULT_OK && data && abl_os_version_check(data) == 0;
  printf("RESULT %s%s\n", avb_slot_verify_result_to_string(r),
         r == AVB_SLOT_VERIFY_RESULT_OK && !abl_ok ? " but ABL_OS_VERSION_REFUSED" : "");
  if (data) {
    for (size_t i = 0; i < data->num_vbmeta_images; i++)
      printf("  vbmeta %-16s verify=%d\n", data->vbmeta_images[i].partition_name,
             data->vbmeta_images[i].verify_result);
    for (size_t i = 0; i < data->num_loaded_partitions; i++)
      printf("  loaded %-16s %zu bytes\n", data->loaded_partitions[i].partition_name,
             data->loaded_partitions[i].data_size);
    for (size_t i = 0; i < AVB_MAX_NUMBER_OF_ROLLBACK_INDEX_LOCATIONS; i++)
      if (data->rollback_indexes[i]) printf("  rollback[%zu] = %llu\n", i,
                                            (unsigned long long)data->rollback_indexes[i]);
    avb_slot_verify_data_free(data);
  }
  return abl_ok ? 0 : 1;
}
