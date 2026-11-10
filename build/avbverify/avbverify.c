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

  const char* requested[] = {"boot", "dtbo", "vendor_boot", "init_boot", NULL};
  AvbSlotVerifyData* data = NULL;
  AvbSlotVerifyResult r = avb_slot_verify(&ops, requested, argv[2], AVB_SLOT_VERIFY_FLAGS_NONE,
                                          AVB_HASHTREE_ERROR_MODE_RESTART_AND_INVALIDATE, &data);
  printf("RESULT %s\n", avb_slot_verify_result_to_string(r));
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
  return r == AVB_SLOT_VERIFY_RESULT_OK ? 0 : 1;
}
