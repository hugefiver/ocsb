#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/openat2.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#ifndef SYS_openat2
#ifdef __NR_openat2
#define SYS_openat2 __NR_openat2
#endif
#endif

#ifndef SYS_renameat2
#ifdef __NR_renameat2
#define SYS_renameat2 __NR_renameat2
#endif
#endif

#define CONFIG_MAGIC "OCSBSCG1"
#define STATE_MAGIC "OCSBSTG1"
#define CONFIG_MAGIC_SIZE 8U
#define STATE_MAGIC_SIZE 8U
#define DIGEST_SIZE 32U
#define HEX_SIZE 64U
#define RECORD_SIZE 176U
#define MAX_VECTOR_COUNT 65536U
#define MAX_STRING_SIZE (1024U * 1024U)
#define MAX_CONFIG_SIZE (64U * 1024U * 1024U)
#define MAX_ARCHIVE_FILE_SIZE (256U * 1024U * 1024U)
#define MAX_ARCHIVE_ENTRIES 4096U

enum record_type {
  RECORD_WAITING = 1,
  RECORD_CURRENT = 2,
  RECORD_PREPARE = 3,
  RECORD_READY_ACK = 4,
  RECORD_DECISION = 5,
  RECORD_COMMIT_ACK = 6,
  RECORD_ABORT_ACK = 7,
};

enum decision_value {
  DECISION_COMMIT = 1,
  DECISION_ABORT = 2,
};

enum execution_mode {
  EXECUTION_SLASH = 1,
  EXECUTION_PATH = 2,
};

struct sha256_context {
  uint32_t state[8];
  uint64_t bit_count;
  unsigned char block[64];
  size_t block_length;
};

struct byte_string {
  unsigned char *bytes;
  size_t length;
};

struct string_vector {
  struct byte_string *items;
  size_t count;
};

struct configuration {
  unsigned char generation[DIGEST_SIZE];
  uint64_t expected_dev;
  uint64_t expected_ino;
  struct string_vector argv;
  struct string_vector environment;
  unsigned char argv_digest[DIGEST_SIZE];
  unsigned char environment_digest[DIGEST_SIZE];
  unsigned char config_digest[DIGEST_SIZE];
  unsigned char *serialized;
  size_t serialized_length;
};

struct state_record {
  enum record_type type;
  uint32_t flags;
  unsigned char generation[DIGEST_SIZE];
  unsigned char run_nonce[DIGEST_SIZE];
  unsigned char config_digest[DIGEST_SIZE];
  unsigned char binding_digest[DIGEST_SIZE];
  unsigned char detail_digest[DIGEST_SIZE];
};

struct state_directory {
  int directory_fd;
  char *directory_path;
  char *config_name;
};

struct active_state {
  struct state_record current;
  struct state_record waiting;
  char generation_hex[HEX_SIZE + 1U];
  char run_hex[HEX_SIZE + 1U];
};

struct acknowledgement_set {
  bool saw_commit;
  bool saw_abort;
  struct state_record commit;
  struct state_record abort;
};

struct parsed_cli {
  const char *mode;
  const char *config_path;
  const char *mount_path;
  const char *generation_text;
  const char *expected_dev_text;
  const char *expected_ino_text;
  const char *entrypoint_json;
  const char *cmd_json;
  const char *environment_json;
  int config_fd;
  int state_archive_fd;
  bool has_config_fd;
  bool has_state_archive_fd;
  bool prepare;
  bool query;
  enum decision_value decision;
  bool decision_option;
  bool wait;
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
  int test_ready_fd;
  int test_release_fd;
  int test_hook_kind;
#endif
};

struct archive_state {
  unsigned char *config_bytes;
  size_t config_length;
  struct state_record *records;
  size_t record_count;
  size_t record_capacity;
  bool saw_binary;
  bool saw_root;
  bool saw_current;
  bool saw_waiting;
  bool saw_prepare;
  bool saw_ready_ack;
  bool saw_decision;
  bool saw_commit_ack;
  bool saw_abort_ack;
  struct state_record current;
  struct state_record waiting;
  struct state_record prepare;
  struct state_record ready_ack;
  struct state_record decision;
  struct state_record commit_ack;
  struct state_record abort_ack;
};

#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
static int wait_for_test_hook(struct parsed_cli *cli, const char *description);
#endif

static void errorf(const char *format, ...) {
  va_list arguments;

  fputs("ocsb-sidecar-gate: ", stderr);
  va_start(arguments, format);
  (void)vfprintf(stderr, format, arguments);
  va_end(arguments);
  fputc('\n', stderr);
}

static int fail_errno(const char *action) {
  const int saved_errno = errno;

  errorf("%s: %s", action, strerror(saved_errno));
  return -1;
}

static int write_all(int file_descriptor, const void *buffer, size_t length) {
  const unsigned char *cursor = buffer;

  while (length != 0U) {
    ssize_t written = write(file_descriptor, cursor, length);

    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (written == 0) {
      errno = EIO;
      return -1;
    }
    cursor += (size_t)written;
    length -= (size_t)written;
  }
  return 0;
}

static int read_all_exact(int file_descriptor, void *buffer, size_t length) {
  unsigned char *cursor = buffer;

  while (length != 0U) {
    ssize_t received = read(file_descriptor, cursor, length);

    if (received < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (received == 0) {
      errno = EPROTO;
      return -1;
    }
    cursor += (size_t)received;
    length -= (size_t)received;
  }
  return 0;
}

static int read_one_byte(int file_descriptor, unsigned char *value_out) {
  for (;;) {
    const ssize_t received = read(file_descriptor, value_out, 1U);

    if (received < 0 && errno == EINTR) {
      continue;
    }
    if (received == 0) {
      return 0;
    }
    return received < 0 ? -1 : 1;
  }
}

static uint32_t rotr32(uint32_t value, unsigned int shift) {
  return (value >> shift) | (value << (32U - shift));
}

static uint32_t load_be32(const unsigned char *bytes) {
  return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) |
         ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static uint64_t load_be64(const unsigned char *bytes) {
  uint64_t value = 0U;
  size_t index;

  for (index = 0U; index < 8U; ++index) {
    value = (value << 8U) | bytes[index];
  }
  return value;
}

static void store_be32(unsigned char *bytes, uint32_t value) {
  bytes[0] = (unsigned char)(value >> 24U);
  bytes[1] = (unsigned char)(value >> 16U);
  bytes[2] = (unsigned char)(value >> 8U);
  bytes[3] = (unsigned char)value;
}

static void store_be64(unsigned char *bytes, uint64_t value) {
  size_t index;

  for (index = 0U; index < 8U; ++index) {
    bytes[7U - index] = (unsigned char)(value & UINT64_C(0xff));
    value >>= 8U;
  }
}

static void sha256_transform(struct sha256_context *context, const unsigned char block[64]) {
  static const uint32_t constants[64] = {
    UINT32_C(0x428a2f98), UINT32_C(0x71374491), UINT32_C(0xb5c0fbcf), UINT32_C(0xe9b5dba5),
    UINT32_C(0x3956c25b), UINT32_C(0x59f111f1), UINT32_C(0x923f82a4), UINT32_C(0xab1c5ed5),
    UINT32_C(0xd807aa98), UINT32_C(0x12835b01), UINT32_C(0x243185be), UINT32_C(0x550c7dc3),
    UINT32_C(0x72be5d74), UINT32_C(0x80deb1fe), UINT32_C(0x9bdc06a7), UINT32_C(0xc19bf174),
    UINT32_C(0xe49b69c1), UINT32_C(0xefbe4786), UINT32_C(0x0fc19dc6), UINT32_C(0x240ca1cc),
    UINT32_C(0x2de92c6f), UINT32_C(0x4a7484aa), UINT32_C(0x5cb0a9dc), UINT32_C(0x76f988da),
    UINT32_C(0x983e5152), UINT32_C(0xa831c66d), UINT32_C(0xb00327c8), UINT32_C(0xbf597fc7),
    UINT32_C(0xc6e00bf3), UINT32_C(0xd5a79147), UINT32_C(0x06ca6351), UINT32_C(0x14292967),
    UINT32_C(0x27b70a85), UINT32_C(0x2e1b2138), UINT32_C(0x4d2c6dfc), UINT32_C(0x53380d13),
    UINT32_C(0x650a7354), UINT32_C(0x766a0abb), UINT32_C(0x81c2c92e), UINT32_C(0x92722c85),
    UINT32_C(0xa2bfe8a1), UINT32_C(0xa81a664b), UINT32_C(0xc24b8b70), UINT32_C(0xc76c51a3),
    UINT32_C(0xd192e819), UINT32_C(0xd6990624), UINT32_C(0xf40e3585), UINT32_C(0x106aa070),
    UINT32_C(0x19a4c116), UINT32_C(0x1e376c08), UINT32_C(0x2748774c), UINT32_C(0x34b0bcb5),
    UINT32_C(0x391c0cb3), UINT32_C(0x4ed8aa4a), UINT32_C(0x5b9cca4f), UINT32_C(0x682e6ff3),
    UINT32_C(0x748f82ee), UINT32_C(0x78a5636f), UINT32_C(0x84c87814), UINT32_C(0x8cc70208),
    UINT32_C(0x90befffa), UINT32_C(0xa4506ceb), UINT32_C(0xbef9a3f7), UINT32_C(0xc67178f2),
  };
  uint32_t words[64];
  uint32_t a;
  uint32_t b;
  uint32_t c;
  uint32_t d;
  uint32_t e;
  uint32_t f;
  uint32_t g;
  uint32_t h;
  size_t index;

  for (index = 0U; index < 16U; ++index) {
    words[index] = load_be32(block + index * 4U);
  }
  for (index = 16U; index < 64U; ++index) {
    const uint32_t small_sigma0 = rotr32(words[index - 15U], 7U) ^
                                  rotr32(words[index - 15U], 18U) ^
                                  (words[index - 15U] >> 3U);
    const uint32_t small_sigma1 = rotr32(words[index - 2U], 17U) ^
                                  rotr32(words[index - 2U], 19U) ^
                                  (words[index - 2U] >> 10U);

    words[index] = words[index - 16U] + small_sigma0 + words[index - 7U] + small_sigma1;
  }

  a = context->state[0];
  b = context->state[1];
  c = context->state[2];
  d = context->state[3];
  e = context->state[4];
  f = context->state[5];
  g = context->state[6];
  h = context->state[7];
  for (index = 0U; index < 64U; ++index) {
    const uint32_t sigma1 = rotr32(e, 6U) ^ rotr32(e, 11U) ^ rotr32(e, 25U);
    const uint32_t choice = (e & f) ^ ((~e) & g);
    const uint32_t temporary1 = h + sigma1 + choice + constants[index] + words[index];
    const uint32_t sigma0 = rotr32(a, 2U) ^ rotr32(a, 13U) ^ rotr32(a, 22U);
    const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t temporary2 = sigma0 + majority;

    h = g;
    g = f;
    f = e;
    e = d + temporary1;
    d = c;
    c = b;
    b = a;
    a = temporary1 + temporary2;
  }
  context->state[0] += a;
  context->state[1] += b;
  context->state[2] += c;
  context->state[3] += d;
  context->state[4] += e;
  context->state[5] += f;
  context->state[6] += g;
  context->state[7] += h;
}

static void sha256_init(struct sha256_context *context) {
  context->state[0] = UINT32_C(0x6a09e667);
  context->state[1] = UINT32_C(0xbb67ae85);
  context->state[2] = UINT32_C(0x3c6ef372);
  context->state[3] = UINT32_C(0xa54ff53a);
  context->state[4] = UINT32_C(0x510e527f);
  context->state[5] = UINT32_C(0x9b05688c);
  context->state[6] = UINT32_C(0x1f83d9ab);
  context->state[7] = UINT32_C(0x5be0cd19);
  context->bit_count = 0U;
  context->block_length = 0U;
}

static void sha256_update(struct sha256_context *context, const void *input, size_t input_length) {
  const unsigned char *bytes = input;

  while (input_length != 0U) {
    const size_t available = 64U - context->block_length;
    const size_t copied = input_length < available ? input_length : available;

    memcpy(context->block + context->block_length, bytes, copied);
    context->block_length += copied;
    context->bit_count += (uint64_t)copied * 8U;
    bytes += copied;
    input_length -= copied;
    if (context->block_length == 64U) {
      sha256_transform(context, context->block);
      context->block_length = 0U;
    }
  }
}

static void sha256_final(struct sha256_context *context, unsigned char digest[DIGEST_SIZE]) {
  size_t index;

  context->block[context->block_length++] = 0x80U;
  if (context->block_length > 56U) {
    while (context->block_length < 64U) {
      context->block[context->block_length++] = 0U;
    }
    sha256_transform(context, context->block);
    context->block_length = 0U;
  }
  while (context->block_length < 56U) {
    context->block[context->block_length++] = 0U;
  }
  store_be64(context->block + 56U, context->bit_count);
  sha256_transform(context, context->block);
  for (index = 0U; index < 8U; ++index) {
    store_be32(digest + index * 4U, context->state[index]);
  }
}

static void sha256_bytes(const void *input, size_t input_length, unsigned char digest[DIGEST_SIZE]) {
  struct sha256_context context;

  sha256_init(&context);
  sha256_update(&context, input, input_length);
  sha256_final(&context, digest);
}

static bool constant_time_equal(const unsigned char *left, const unsigned char *right, size_t length) {
  unsigned char different = 0U;
  size_t index;

  for (index = 0U; index < length; ++index) {
    different |= (unsigned char)(left[index] ^ right[index]);
  }
  return different == 0U;
}

static void vector_free(struct string_vector *vector) {
  size_t index;

  for (index = 0U; index < vector->count; ++index) {
    free(vector->items[index].bytes);
  }
  free(vector->items);
  vector->items = NULL;
  vector->count = 0U;
}

static void configuration_free(struct configuration *configuration) {
  vector_free(&configuration->argv);
  vector_free(&configuration->environment);
  free(configuration->serialized);
  memset(configuration, 0, sizeof(*configuration));
}

static int vector_append(struct string_vector *vector, const unsigned char *bytes, size_t length) {
  struct byte_string *expanded;
  unsigned char *copy;

  if (length > MAX_STRING_SIZE || vector->count >= MAX_VECTOR_COUNT) {
    errno = EINVAL;
    return -1;
  }
  if (length != 0U && memchr(bytes, '\0', length) != NULL) {
    errno = EINVAL;
    return -1;
  }
  if (vector->count > SIZE_MAX / sizeof(*expanded) - 1U) {
    errno = EOVERFLOW;
    return -1;
  }
  copy = malloc(length + 1U);
  if (copy == NULL) {
    return -1;
  }
  if (length != 0U) {
    memcpy(copy, bytes, length);
  }
  copy[length] = '\0';
  expanded = realloc(vector->items, (vector->count + 1U) * sizeof(*expanded));
  if (expanded == NULL) {
    free(copy);
    return -1;
  }
  vector->items = expanded;
  vector->items[vector->count].bytes = copy;
  vector->items[vector->count].length = length;
  ++vector->count;
  return 0;
}

static int hex_value(unsigned char character) {
  if (character >= '0' && character <= '9') {
    return (int)(character - '0');
  }
  if (character >= 'a' && character <= 'f') {
    return (int)(character - 'a' + 10U);
  }
  if (character >= 'A' && character <= 'F') {
    return (int)(character - 'A' + 10U);
  }
  return -1;
}

static int parse_hex_64(const char *text, unsigned char output[DIGEST_SIZE]) {
  size_t index;

  if (strlen(text) != HEX_SIZE) {
    return -1;
  }
  for (index = 0U; index < DIGEST_SIZE; ++index) {
    const int high = hex_value((unsigned char)text[index * 2U]);
    const int low = hex_value((unsigned char)text[index * 2U + 1U]);

    if (high < 0 || low < 0) {
      return -1;
    }
    output[index] = (unsigned char)((unsigned int)high << 4U) | (unsigned char)low;
  }
  return 0;
}

static void hex_encode_64(const unsigned char input[DIGEST_SIZE], char output[HEX_SIZE + 1U]) {
  static const char alphabet[] = "0123456789abcdef";
  size_t index;

  for (index = 0U; index < DIGEST_SIZE; ++index) {
    output[index * 2U] = alphabet[input[index] >> 4U];
    output[index * 2U + 1U] = alphabet[input[index] & 0x0fU];
  }
  output[HEX_SIZE] = '\0';
}

static int parse_uint64_decimal(const char *text, uint64_t *value_out) {
  uint64_t value = 0U;
  const unsigned char *cursor = (const unsigned char *)text;

  if (*cursor == '\0') {
    return -1;
  }
  for (; *cursor != '\0'; ++cursor) {
    const unsigned int digit = (unsigned int)(*cursor - (unsigned char)'0');

    if (*cursor < (unsigned char)'0' || *cursor > (unsigned char)'9' ||
        value > (UINT64_MAX - digit) / 10U) {
      return -1;
    }
    value = value * 10U + digit;
  }
  *value_out = value;
  return 0;
}

static int parse_fd(const char *text, int *file_descriptor_out) {
  uint64_t value;

  if (parse_uint64_decimal(text, &value) != 0 || value > (uint64_t)INT_MAX) {
    return -1;
  }
  *file_descriptor_out = (int)value;
  return 0;
}

static const unsigned char *json_skip_whitespace(const unsigned char *cursor) {
  while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' || *cursor == '\r') {
    ++cursor;
  }
  return cursor;
}

static int append_json_byte(unsigned char **buffer, size_t *length, size_t *capacity,
                            unsigned char value) {
  unsigned char *expanded;
  size_t next_capacity;

  if (value == '\0' || *length >= MAX_STRING_SIZE) {
    errno = EINVAL;
    return -1;
  }
  if (*length == *capacity) {
    next_capacity = *capacity == 0U ? 64U : *capacity * 2U;
    if (next_capacity < *capacity || next_capacity > MAX_STRING_SIZE) {
      next_capacity = MAX_STRING_SIZE;
    }
    if (next_capacity <= *capacity) {
      errno = EOVERFLOW;
      return -1;
    }
    expanded = realloc(*buffer, next_capacity);
    if (expanded == NULL) {
      return -1;
    }
    *buffer = expanded;
    *capacity = next_capacity;
  }
  (*buffer)[(*length)++] = value;
  return 0;
}

static int append_json_utf8(unsigned char **buffer, size_t *length, size_t *capacity,
                            uint32_t codepoint) {
  if (codepoint == 0U || codepoint > UINT32_C(0x10ffff) ||
      (codepoint >= UINT32_C(0xd800) && codepoint <= UINT32_C(0xdfff))) {
    errno = EINVAL;
    return -1;
  }
  if (codepoint <= UINT32_C(0x7f)) {
    return append_json_byte(buffer, length, capacity, (unsigned char)codepoint);
  }
  if (codepoint <= UINT32_C(0x7ff)) {
    return append_json_byte(buffer, length, capacity, (unsigned char)(0xc0U | (codepoint >> 6U))) ||
                   append_json_byte(buffer, length, capacity,
                                    (unsigned char)(0x80U | (codepoint & 0x3fU)))
               ? -1
               : 0;
  }
  if (codepoint <= UINT32_C(0xffff)) {
    return append_json_byte(buffer, length, capacity, (unsigned char)(0xe0U | (codepoint >> 12U))) ||
                   append_json_byte(buffer, length, capacity,
                                    (unsigned char)(0x80U | ((codepoint >> 6U) & 0x3fU))) ||
                   append_json_byte(buffer, length, capacity,
                                    (unsigned char)(0x80U | (codepoint & 0x3fU)))
               ? -1
               : 0;
  }
  return append_json_byte(buffer, length, capacity, (unsigned char)(0xf0U | (codepoint >> 18U))) ||
                 append_json_byte(buffer, length, capacity,
                                  (unsigned char)(0x80U | ((codepoint >> 12U) & 0x3fU))) ||
                 append_json_byte(buffer, length, capacity,
                                  (unsigned char)(0x80U | ((codepoint >> 6U) & 0x3fU))) ||
                 append_json_byte(buffer, length, capacity,
                                  (unsigned char)(0x80U | (codepoint & 0x3fU)))
             ? -1
             : 0;
}

static int validate_utf8(const unsigned char *bytes, size_t length) {
  size_t index = 0U;

  while (index < length) {
    const unsigned char first = bytes[index++];
    unsigned int continuation_count;
    unsigned char minimum_second = 0x80U;
    unsigned char maximum_second = 0xbfU;
    size_t continuation_index;

    if (first <= 0x7fU) {
      continue;
    }
    if (first >= 0xc2U && first <= 0xdfU) {
      continuation_count = 1U;
    } else if (first == 0xe0U) {
      continuation_count = 2U;
      minimum_second = 0xa0U;
    } else if (first >= 0xe1U && first <= 0xecU) {
      continuation_count = 2U;
    } else if (first == 0xedU) {
      continuation_count = 2U;
      maximum_second = 0x9fU;
    } else if (first >= 0xeeU && first <= 0xefU) {
      continuation_count = 2U;
    } else if (first == 0xf0U) {
      continuation_count = 3U;
      minimum_second = 0x90U;
    } else if (first >= 0xf1U && first <= 0xf3U) {
      continuation_count = 3U;
    } else if (first == 0xf4U) {
      continuation_count = 3U;
      maximum_second = 0x8fU;
    } else {
      errno = EINVAL;
      return -1;
    }
    if (index + continuation_count > length || bytes[index] < minimum_second ||
        bytes[index] > maximum_second) {
      errno = EINVAL;
      return -1;
    }
    for (continuation_index = 1U; continuation_index < continuation_count; ++continuation_index) {
      if (bytes[index + continuation_index] < 0x80U || bytes[index + continuation_index] > 0xbfU) {
        errno = EINVAL;
        return -1;
      }
    }
    index += continuation_count;
  }
  return 0;
}

static int parse_json_hex4(const unsigned char **cursor_in_out, uint32_t *value_out) {
  const unsigned char *cursor = *cursor_in_out;
  uint32_t value = 0U;
  size_t index;

  for (index = 0U; index < 4U; ++index) {
    const int digit = hex_value(cursor[index]);

    if (digit < 0) {
      errno = EINVAL;
      return -1;
    }
    value = (value << 4U) | (uint32_t)digit;
  }
  *cursor_in_out = cursor + 4U;
  *value_out = value;
  return 0;
}

static int parse_json_string(const unsigned char **cursor_in_out, struct byte_string *string_out) {
  const unsigned char *cursor = *cursor_in_out;
  unsigned char *buffer = NULL;
  size_t length = 0U;
  size_t capacity = 0U;

  if (*cursor != '"') {
    errno = EINVAL;
    return -1;
  }
  ++cursor;
  while (*cursor != '\0' && *cursor != '"') {
    unsigned char character = *cursor++;

    if (character < 0x20U) {
      errno = EINVAL;
      goto failure;
    }
    if (character != '\\') {
      if (append_json_byte(&buffer, &length, &capacity, character) != 0) {
        goto failure;
      }
      continue;
    }
    character = *cursor++;
    switch (character) {
      case '"':
      case '\\':
      case '/':
        if (append_json_byte(&buffer, &length, &capacity, character) != 0) {
          goto failure;
        }
        break;
      case 'b':
        if (append_json_byte(&buffer, &length, &capacity, '\b') != 0) {
          goto failure;
        }
        break;
      case 'f':
        if (append_json_byte(&buffer, &length, &capacity, '\f') != 0) {
          goto failure;
        }
        break;
      case 'n':
        if (append_json_byte(&buffer, &length, &capacity, '\n') != 0) {
          goto failure;
        }
        break;
      case 'r':
        if (append_json_byte(&buffer, &length, &capacity, '\r') != 0) {
          goto failure;
        }
        break;
      case 't':
        if (append_json_byte(&buffer, &length, &capacity, '\t') != 0) {
          goto failure;
        }
        break;
      case 'u': {
        uint32_t codepoint;

        if (parse_json_hex4(&cursor, &codepoint) != 0) {
          goto failure;
        }
        if (codepoint >= UINT32_C(0xd800) && codepoint <= UINT32_C(0xdbff)) {
          uint32_t low_surrogate;

          if (cursor[0] != '\\' || cursor[1] != 'u') {
            errno = EINVAL;
            goto failure;
          }
          cursor += 2U;
          if (parse_json_hex4(&cursor, &low_surrogate) != 0 ||
              low_surrogate < UINT32_C(0xdc00) || low_surrogate > UINT32_C(0xdfff)) {
            errno = EINVAL;
            goto failure;
          }
          codepoint = UINT32_C(0x10000) + ((codepoint - UINT32_C(0xd800)) << 10U) +
                      (low_surrogate - UINT32_C(0xdc00));
        } else if (codepoint >= UINT32_C(0xdc00) && codepoint <= UINT32_C(0xdfff)) {
          errno = EINVAL;
          goto failure;
        }
        if (append_json_utf8(&buffer, &length, &capacity, codepoint) != 0) {
          goto failure;
        }
        break;
      }
      default:
        errno = EINVAL;
        goto failure;
    }
  }
  if (*cursor != '"') {
    errno = EINVAL;
    goto failure;
  }
  ++cursor;
  if (validate_utf8(buffer, length) != 0) {
    goto failure;
  }
  string_out->bytes = buffer;
  string_out->length = length;
  *cursor_in_out = cursor;
  return 0;

failure:
  free(buffer);
  return -1;
}

static int parse_json_vector(const char *text, struct string_vector *vector_out) {
  const unsigned char *cursor = json_skip_whitespace((const unsigned char *)text);
  struct string_vector parsed = { 0 };

  if (strncmp((const char *)cursor, "null", 4U) == 0 &&
      *json_skip_whitespace(cursor + 4U) == '\0') {
    *vector_out = parsed;
    return 0;
  }
  if (*cursor != '[') {
    errno = EINVAL;
    return -1;
  }
  ++cursor;
  cursor = json_skip_whitespace(cursor);
  if (*cursor == ']') {
    ++cursor;
  } else {
    for (;;) {
      struct byte_string item = { 0 };

      cursor = json_skip_whitespace(cursor);
      if (parse_json_string(&cursor, &item) != 0 ||
          vector_append(&parsed, item.bytes, item.length) != 0) {
        free(item.bytes);
        vector_free(&parsed);
        return -1;
      }
      free(item.bytes);
      cursor = json_skip_whitespace(cursor);
      if (*cursor == ']') {
        ++cursor;
        break;
      }
      if (*cursor != ',') {
        errno = EINVAL;
        vector_free(&parsed);
        return -1;
      }
      ++cursor;
    }
  }
  if (*json_skip_whitespace(cursor) != '\0') {
    errno = EINVAL;
    vector_free(&parsed);
    return -1;
  }
  *vector_out = parsed;
  return 0;
}

static int validate_environment(const struct string_vector *environment, const unsigned char **path_out,
                                size_t *path_length_out) {
  const unsigned char *path = NULL;
  size_t path_length = 0U;
  size_t index;

  for (index = 0U; index < environment->count; ++index) {
    const struct byte_string *item = &environment->items[index];

    if (item->length >= 5U && memcmp(item->bytes, "PATH=", 5U) == 0) {
      if (path != NULL) {
        errno = EINVAL;
        return -1;
      }
      path = item->bytes + 5U;
      path_length = item->length - 5U;
    }
  }
  if (path == NULL) {
    errno = EINVAL;
    return -1;
  }
  *path_out = path;
  *path_length_out = path_length;
  return 0;
}

static void vector_digest(const struct string_vector *vector, unsigned char digest[DIGEST_SIZE]) {
  struct sha256_context context;
  size_t index;
  static const unsigned char separator = '\0';

  sha256_init(&context);
  for (index = 0U; index < vector->count; ++index) {
    sha256_update(&context, vector->items[index].bytes, vector->items[index].length);
    sha256_update(&context, &separator, 1U);
  }
  sha256_final(&context, digest);
}

static int serialize_vector(const struct string_vector *vector, unsigned char **cursor_in_out,
                            const unsigned char *end) {
  size_t index;
  unsigned char *cursor = *cursor_in_out;

  if (vector->count > UINT32_MAX || (size_t)(end - cursor) < 4U) {
    errno = EOVERFLOW;
    return -1;
  }
  store_be32(cursor, (uint32_t)vector->count);
  cursor += 4U;
  for (index = 0U; index < vector->count; ++index) {
    const struct byte_string *item = &vector->items[index];

    if (item->length > UINT32_MAX || (size_t)(end - cursor) < 4U + item->length) {
      errno = EOVERFLOW;
      return -1;
    }
    store_be32(cursor, (uint32_t)item->length);
    cursor += 4U;
    memcpy(cursor, item->bytes, item->length);
    cursor += item->length;
  }
  *cursor_in_out = cursor;
  return 0;
}

static int decode_vector(const unsigned char **cursor_in_out, const unsigned char *end,
                         struct string_vector *vector_out) {
  const unsigned char *cursor = *cursor_in_out;
  struct string_vector parsed = { 0 };
  uint32_t count;
  uint32_t index;

  if ((size_t)(end - cursor) < 4U) {
    errno = EPROTO;
    return -1;
  }
  count = load_be32(cursor);
  cursor += 4U;
  if (count > MAX_VECTOR_COUNT) {
    errno = EPROTO;
    return -1;
  }
  for (index = 0U; index < count; ++index) {
    uint32_t length;

    if ((size_t)(end - cursor) < 4U) {
      errno = EPROTO;
      goto failure;
    }
    length = load_be32(cursor);
    cursor += 4U;
    if (length > MAX_STRING_SIZE || (size_t)(end - cursor) < length ||
        vector_append(&parsed, cursor, length) != 0) {
      if (errno == 0) {
        errno = EPROTO;
      }
      goto failure;
    }
    cursor += length;
  }
  *cursor_in_out = cursor;
  *vector_out = parsed;
  return 0;

failure:
  vector_free(&parsed);
  return -1;
}

static int serialize_configuration(struct configuration *configuration) {
  size_t length = CONFIG_MAGIC_SIZE + DIGEST_SIZE + 8U + 8U + 4U + DIGEST_SIZE + 4U + DIGEST_SIZE;
  unsigned char *serialized;
  unsigned char *cursor;
  const unsigned char *end;
  size_t index;

  for (index = 0U; index < configuration->argv.count; ++index) {
    if (configuration->argv.items[index].length > SIZE_MAX - length - 4U) {
      errno = EOVERFLOW;
      return -1;
    }
    length += 4U + configuration->argv.items[index].length;
  }
  for (index = 0U; index < configuration->environment.count; ++index) {
    if (configuration->environment.items[index].length > SIZE_MAX - length - 4U) {
      errno = EOVERFLOW;
      return -1;
    }
    length += 4U + configuration->environment.items[index].length;
  }
  if (length > MAX_CONFIG_SIZE) {
    errno = EOVERFLOW;
    return -1;
  }
  serialized = malloc(length);
  if (serialized == NULL) {
    return -1;
  }
  cursor = serialized;
  end = serialized + length;
  memcpy(cursor, CONFIG_MAGIC, CONFIG_MAGIC_SIZE);
  cursor += CONFIG_MAGIC_SIZE;
  memcpy(cursor, configuration->generation, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  store_be64(cursor, configuration->expected_dev);
  cursor += 8U;
  store_be64(cursor, configuration->expected_ino);
  cursor += 8U;
  if (serialize_vector(&configuration->argv, &cursor, end) != 0) {
    free(serialized);
    return -1;
  }
  memcpy(cursor, configuration->argv_digest, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  if (serialize_vector(&configuration->environment, &cursor, end) != 0) {
    free(serialized);
    return -1;
  }
  memcpy(cursor, configuration->environment_digest, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  if (cursor != end) {
    free(serialized);
    errno = EPROTO;
    return -1;
  }
  configuration->serialized = serialized;
  configuration->serialized_length = length;
  sha256_bytes(serialized, length, configuration->config_digest);
  return 0;
}

static int decode_configuration_bytes(const unsigned char *bytes, size_t length,
                                      struct configuration *configuration_out) {
  const unsigned char *cursor = bytes;
  const unsigned char *end = bytes + length;
  struct configuration parsed = { 0 };
  unsigned char digest[DIGEST_SIZE];
  const unsigned char *path;
  size_t path_length;

  if (length < CONFIG_MAGIC_SIZE + DIGEST_SIZE + 16U + 4U + DIGEST_SIZE + 4U + DIGEST_SIZE ||
      memcmp(cursor, CONFIG_MAGIC, CONFIG_MAGIC_SIZE) != 0) {
    errno = EPROTO;
    return -1;
  }
  cursor += CONFIG_MAGIC_SIZE;
  memcpy(parsed.generation, cursor, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  parsed.expected_dev = load_be64(cursor);
  cursor += 8U;
  parsed.expected_ino = load_be64(cursor);
  cursor += 8U;
  if (parsed.expected_dev == 0U || parsed.expected_ino == 0U ||
      decode_vector(&cursor, end, &parsed.argv) != 0 || parsed.argv.count == 0U ||
      (size_t)(end - cursor) < DIGEST_SIZE) {
    errno = EPROTO;
    goto failure;
  }
  memcpy(parsed.argv_digest, cursor, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  vector_digest(&parsed.argv, digest);
  if (!constant_time_equal(digest, parsed.argv_digest, DIGEST_SIZE) ||
      decode_vector(&cursor, end, &parsed.environment) != 0 || (size_t)(end - cursor) < DIGEST_SIZE) {
    errno = EPROTO;
    goto failure;
  }
  memcpy(parsed.environment_digest, cursor, DIGEST_SIZE);
  cursor += DIGEST_SIZE;
  vector_digest(&parsed.environment, digest);
  if (!constant_time_equal(digest, parsed.environment_digest, DIGEST_SIZE) || cursor != end ||
      validate_environment(&parsed.environment, &path, &path_length) != 0) {
    errno = EPROTO;
    goto failure;
  }
  (void)path;
  (void)path_length;
  parsed.serialized = malloc(length);
  if (parsed.serialized == NULL) {
    goto failure;
  }
  memcpy(parsed.serialized, bytes, length);
  parsed.serialized_length = length;
  sha256_bytes(bytes, length, parsed.config_digest);
  *configuration_out = parsed;
  return 0;

failure:
  configuration_free(&parsed);
  return -1;
}

static int read_configuration_fd(int file_descriptor, struct configuration *configuration_out) {
  struct stat status;
  unsigned char *bytes;
  int result;

  if (fstat(file_descriptor, &status) != 0) {
    return -1;
  }
  if (!S_ISREG(status.st_mode) || status.st_size < 0 || (uintmax_t)status.st_size > MAX_CONFIG_SIZE ||
      lseek(file_descriptor, 0, SEEK_SET) < 0) {
    errno = EINVAL;
    return -1;
  }
  bytes = malloc((size_t)status.st_size == 0U ? 1U : (size_t)status.st_size);
  if (bytes == NULL) {
    return -1;
  }
  if (read_all_exact(file_descriptor, bytes, (size_t)status.st_size) != 0) {
    free(bytes);
    return -1;
  }
  result = decode_configuration_bytes(bytes, (size_t)status.st_size, configuration_out);
  free(bytes);
  return result;
}

static int write_configuration_fd(int file_descriptor, const struct configuration *configuration) {
  if (ftruncate(file_descriptor, 0) != 0 || lseek(file_descriptor, 0, SEEK_SET) < 0 ||
      write_all(file_descriptor, configuration->serialized, configuration->serialized_length) != 0 ||
      fsync(file_descriptor) != 0) {
    return -1;
  }
  return 0;
}

static int validate_absolute_path(const char *path) {
  size_t index;
  size_t component_start;
  const size_t length = strlen(path);

  if (path[0] != '/' || length <= 1U || length >= PATH_MAX || path[length - 1U] == '/') {
    return -1;
  }
  component_start = 1U;
  for (index = 1U; index <= length; ++index) {
    if (path[index] == '/' || path[index] == '\0') {
      const size_t component_length = index - component_start;

      if (component_length == 0U || component_length > NAME_MAX ||
          (component_length == 1U && path[component_start] == '.') ||
          (component_length == 2U && path[component_start] == '.' &&
           path[component_start + 1U] == '.')) {
        return -1;
      }
      component_start = index + 1U;
    }
  }
  return 0;
}

static int open_state_directory(const char *config_path, struct state_directory *directory_out) {
  const char *slash;
  size_t parent_length;
  struct state_directory directory = { .directory_fd = -1 };

  if (validate_absolute_path(config_path) != 0) {
    errno = EINVAL;
    return -1;
  }
  slash = strrchr(config_path, '/');
  if (slash == NULL || slash[1] == '\0') {
    errno = EINVAL;
    return -1;
  }
  parent_length = slash == config_path ? 1U : (size_t)(slash - config_path);
  directory.directory_path = malloc(parent_length + 1U);
  directory.config_name = strdup(slash + 1);
  if (directory.directory_path == NULL || directory.config_name == NULL) {
    free(directory.directory_path);
    free(directory.config_name);
    return -1;
  }
  memcpy(directory.directory_path, config_path, parent_length);
  directory.directory_path[parent_length] = '\0';
  directory.directory_fd = open(directory.directory_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (directory.directory_fd < 0) {
    free(directory.directory_path);
    free(directory.config_name);
    return -1;
  }
  *directory_out = directory;
  return 0;
}

static void close_state_directory(struct state_directory *directory) {
  if (directory->directory_fd >= 0) {
    (void)close(directory->directory_fd);
  }
  free(directory->directory_path);
  free(directory->config_name);
  directory->directory_fd = -1;
  directory->directory_path = NULL;
  directory->config_name = NULL;
}

static int lock_state_directory(int directory_fd, int operation) {
  int result;

  do {
    result = flock(directory_fd, operation);
  } while (result != 0 && errno == EINTR);
  return result;
}

static int unlock_state_directory(int directory_fd) {
  return lock_state_directory(directory_fd, LOCK_UN);
}

static int finish_state_directory_lock(int directory_fd, int result) {
  const int saved_errno = errno;

  if (unlock_state_directory(directory_fd) != 0) {
    return -1;
  }
  if (result != 0) {
    errno = saved_errno;
  }
  return result;
}

static int read_configuration_path(const struct state_directory *directory,
                                   struct configuration *configuration_out) {
  int file_descriptor = openat(directory->directory_fd, directory->config_name,
                               O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat status;
  int result;

  if (file_descriptor < 0) {
    return -1;
  }
  if (fstat(file_descriptor, &status) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  if (!S_ISREG(status.st_mode) || (status.st_mode & 07777U) != 0600U || status.st_nlink != 1U) {
    (void)close(file_descriptor);
    errno = EPROTO;
    return -1;
  }
  result = read_configuration_fd(file_descriptor, configuration_out);
  (void)close(file_descriptor);
  return result;
}

static void record_serialize(const struct state_record *record, unsigned char bytes[RECORD_SIZE]) {
  memset(bytes, 0, RECORD_SIZE);
  memcpy(bytes, STATE_MAGIC, STATE_MAGIC_SIZE);
  store_be32(bytes + 8U, (uint32_t)record->type);
  store_be32(bytes + 12U, record->flags);
  memcpy(bytes + 16U, record->generation, DIGEST_SIZE);
  memcpy(bytes + 48U, record->run_nonce, DIGEST_SIZE);
  memcpy(bytes + 80U, record->config_digest, DIGEST_SIZE);
  memcpy(bytes + 112U, record->binding_digest, DIGEST_SIZE);
  memcpy(bytes + 144U, record->detail_digest, DIGEST_SIZE);
}

static int record_deserialize(const unsigned char bytes[RECORD_SIZE], struct state_record *record_out) {
  struct state_record record = { 0 };
  uint32_t type;

  if (memcmp(bytes, STATE_MAGIC, STATE_MAGIC_SIZE) != 0) {
    errno = EPROTO;
    return -1;
  }
  type = load_be32(bytes + 8U);
  if (type < RECORD_WAITING || type > RECORD_ABORT_ACK) {
    errno = EPROTO;
    return -1;
  }
  record.type = (enum record_type)type;
  record.flags = load_be32(bytes + 12U);
  memcpy(record.generation, bytes + 16U, DIGEST_SIZE);
  memcpy(record.run_nonce, bytes + 48U, DIGEST_SIZE);
  memcpy(record.config_digest, bytes + 80U, DIGEST_SIZE);
  memcpy(record.binding_digest, bytes + 112U, DIGEST_SIZE);
  memcpy(record.detail_digest, bytes + 144U, DIGEST_SIZE);
  *record_out = record;
  return 0;
}

static int validate_record_shape(const struct state_record *record) {
  static const unsigned char zero[DIGEST_SIZE] = { 0 };

  switch (record->type) {
    case RECORD_WAITING:
    case RECORD_PREPARE:
    case RECORD_READY_ACK:
      if (record->flags != 0U || !constant_time_equal(record->binding_digest, zero, DIGEST_SIZE) ||
          !constant_time_equal(record->detail_digest, zero, DIGEST_SIZE)) {
        errno = EPROTO;
        return -1;
      }
      break;
    case RECORD_CURRENT:
      if ((record->flags != 0U && record->flags != 1U) ||
          !constant_time_equal(record->binding_digest, zero, DIGEST_SIZE) ||
          !constant_time_equal(record->detail_digest, zero, DIGEST_SIZE)) {
        errno = EPROTO;
        return -1;
      }
      break;
    case RECORD_DECISION:
      if ((record->flags != DECISION_COMMIT && record->flags != DECISION_ABORT) ||
          !constant_time_equal(record->binding_digest, zero, DIGEST_SIZE) ||
          !constant_time_equal(record->detail_digest, zero, DIGEST_SIZE)) {
        errno = EPROTO;
        return -1;
      }
      break;
    case RECORD_COMMIT_ACK:
      if ((record->flags != EXECUTION_SLASH && record->flags != EXECUTION_PATH) ||
          constant_time_equal(record->binding_digest, zero, DIGEST_SIZE) ||
          constant_time_equal(record->detail_digest, zero, DIGEST_SIZE)) {
        errno = EPROTO;
        return -1;
      }
      break;
    case RECORD_ABORT_ACK:
      if (record->flags != 0U || constant_time_equal(record->binding_digest, zero, DIGEST_SIZE) ||
          !constant_time_equal(record->detail_digest, zero, DIGEST_SIZE)) {
        errno = EPROTO;
        return -1;
      }
      break;
  }
  return 0;
}

static int read_record_at_unlocked(int directory_fd, const char *name, enum record_type expected_type,
                                   struct state_record *record_out) {
  unsigned char bytes[RECORD_SIZE];
  struct stat status;
  int file_descriptor;

  file_descriptor = openat(directory_fd, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (file_descriptor < 0) {
    return -1;
  }
  if (fstat(file_descriptor, &status) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  if (!S_ISREG(status.st_mode) || (status.st_mode & 07777U) != 0600U || status.st_nlink != 1U ||
      status.st_uid != getuid() || status.st_size != (off_t)RECORD_SIZE) {
    (void)close(file_descriptor);
    errno = EPROTO;
    return -1;
  }
  if (read_all_exact(file_descriptor, bytes, sizeof(bytes)) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  if (record_deserialize(bytes, record_out) != 0 || record_out->type != expected_type ||
      validate_record_shape(record_out) != 0) {
    (void)close(file_descriptor);
    errno = EPROTO;
    return -1;
  }
  /* A writer that dies after publishing a complete record but before syncing
   * the directory releases its exclusive state lock.  The first validating
   * reader must finish both durability barriers before it can act on that
   * record; malformed/partial files still fail above without promotion. */
  if (fsync(file_descriptor) != 0 || close(file_descriptor) != 0 || fsync(directory_fd) != 0) {
    return -1;
  }
  return 0;
}

static int read_record_at(int directory_fd, const char *name, enum record_type expected_type,
                          struct state_record *record_out) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = read_record_at_unlocked(directory_fd, name, expected_type, record_out);
  return finish_state_directory_lock(directory_fd, result);
}

static int make_state_name(char *buffer, size_t buffer_size, const char *prefix,
                           const char *generation_hex, const char *run_hex);

static int validate_record_fd(int file_descriptor, enum record_type expected_type,
                              const struct state_record *expected_record) {
  unsigned char bytes[RECORD_SIZE];
  unsigned char expected_bytes[RECORD_SIZE];
  struct state_record observed_record;
  struct stat status;

  if (fstat(file_descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
      (status.st_mode & 07777U) != 0600U || status.st_nlink != 1U ||
      status.st_uid != getuid() || status.st_size != (off_t)RECORD_SIZE ||
      lseek(file_descriptor, 0, SEEK_SET) != 0 || read_all_exact(file_descriptor, bytes, sizeof(bytes)) != 0 ||
      record_deserialize(bytes, &observed_record) != 0 || observed_record.type != expected_type ||
      validate_record_shape(&observed_record) != 0) {
    errno = EPROTO;
    return -1;
  }
  record_serialize(expected_record, expected_bytes);
  if (!constant_time_equal(bytes, expected_bytes, sizeof(bytes))) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int open_waiting_liveness(int directory_fd, const char *waiting_name,
                                 const struct state_record *expected_waiting) {
  int file_descriptor = openat(directory_fd, waiting_name, O_RDONLY | O_NOFOLLOW);

  if (file_descriptor < 0) {
    return -1;
  }
  if (lock_state_directory(file_descriptor, LOCK_EX) != 0 ||
      validate_record_fd(file_descriptor, RECORD_WAITING, expected_waiting) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  return file_descriptor;
}

static int active_waiting_is_live(int directory_fd, const struct active_state *active) {
  char waiting_name[NAME_MAX + 1U];
  int file_descriptor;
  int lock_result;

  if (make_state_name(waiting_name, sizeof(waiting_name), "waiting", active->generation_hex,
                      active->run_hex) != 0) {
    return -1;
  }
  file_descriptor = openat(directory_fd, waiting_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (file_descriptor < 0) {
    return errno == ENOENT ? 1 : -1;
  }
  if (validate_record_fd(file_descriptor, RECORD_WAITING, &active->waiting) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  lock_result = flock(file_descriptor, LOCK_SH | LOCK_NB);
  if (lock_result == 0) {
    (void)flock(file_descriptor, LOCK_UN);
    (void)close(file_descriptor);
    return 1;
  }
  if (errno != EWOULDBLOCK && errno != EAGAIN) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    errno = saved_errno;
    return -1;
  }
  if (close(file_descriptor) != 0) {
    return -1;
  }
  return 0;
}

static int write_record_new_unlocked(int directory_fd, const char *name, const struct state_record *record) {
  unsigned char bytes[RECORD_SIZE];
  static uint64_t temporary_sequence;
  char temporary_name[NAME_MAX + 1U];
  int file_descriptor;
  int formatted;

  record_serialize(record, bytes);
  ++temporary_sequence;
  formatted = snprintf(temporary_name, sizeof(temporary_name), ".record-%ld-%" PRIu64,
                       (long)getpid(), temporary_sequence);
  if (formatted < 0 || (size_t)formatted >= sizeof(temporary_name)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  file_descriptor = openat(directory_fd, temporary_name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                           0600U);
  if (file_descriptor < 0) {
    return -1;
  }
  if (fchmod(file_descriptor, 0600U) != 0 || write_all(file_descriptor, bytes, sizeof(bytes)) != 0 ||
      fsync(file_descriptor) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    (void)unlinkat(directory_fd, temporary_name, 0);
    errno = saved_errno;
    return -1;
  }
  if (close(file_descriptor) != 0) {
    const int saved_errno = errno;

    (void)unlinkat(directory_fd, temporary_name, 0);
    errno = saved_errno;
    return -1;
  }
  if (syscall(SYS_renameat2, directory_fd, temporary_name, directory_fd, name, RENAME_NOREPLACE) != 0) {
    const int saved_errno = errno;

    (void)unlinkat(directory_fd, temporary_name, 0);
    errno = saved_errno;
    return -1;
  }
  if (fsync(directory_fd) != 0) {
    return -1;
  }
  return 0;
}

static int write_record_new(int directory_fd, const char *name, const struct state_record *record) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_EX) != 0) {
    return -1;
  }
  result = write_record_new_unlocked(directory_fd, name, record);
  return finish_state_directory_lock(directory_fd, result);
}

static int write_current_atomic_unlocked(int directory_fd, const char *current_name,
                                         const struct state_record *record) {
  unsigned char bytes[RECORD_SIZE];
  char temporary_name[NAME_MAX + 1U];
  char run_hex[HEX_SIZE + 1U];
  int file_descriptor;
  int formatted;

  hex_encode_64(record->run_nonce, run_hex);
  formatted = snprintf(temporary_name, sizeof(temporary_name), ".current-%s", run_hex);
  if (formatted < 0 || (size_t)formatted >= sizeof(temporary_name)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  record_serialize(record, bytes);
  file_descriptor = openat(directory_fd, temporary_name,
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600U);
  if (file_descriptor < 0) {
    return -1;
  }
  if (fchmod(file_descriptor, 0600U) != 0 || write_all(file_descriptor, bytes, sizeof(bytes)) != 0 ||
      fsync(file_descriptor) != 0) {
    const int saved_errno = errno;

    (void)close(file_descriptor);
    (void)unlinkat(directory_fd, temporary_name, 0);
    errno = saved_errno;
    return -1;
  }
  if (close(file_descriptor) != 0 || renameat(directory_fd, temporary_name, directory_fd, current_name) != 0 ||
      fsync(directory_fd) != 0) {
    const int saved_errno = errno;

    (void)unlinkat(directory_fd, temporary_name, 0);
    errno = saved_errno;
    return -1;
  }
  return 0;
}

static int write_current_atomic(int directory_fd, const char *current_name,
                                const struct state_record *record) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_EX) != 0) {
    return -1;
  }
  result = write_current_atomic_unlocked(directory_fd, current_name, record);
  return finish_state_directory_lock(directory_fd, result);
}

static int write_verified_current_if_same_run(int directory_fd, const char *current_name,
                                               const struct state_record *expected_current) {
  struct state_record observed_current;
  int result = -1;

  if (lock_state_directory(directory_fd, LOCK_EX) != 0) {
    return -1;
  }
  if (read_record_at_unlocked(directory_fd, current_name, RECORD_CURRENT, &observed_current) != 0) {
    goto cleanup;
  }
  if (!constant_time_equal(observed_current.generation, expected_current->generation, DIGEST_SIZE) ||
      !constant_time_equal(observed_current.run_nonce, expected_current->run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(observed_current.config_digest, expected_current->config_digest, DIGEST_SIZE)) {
    result = 1;
    goto cleanup;
  }
  observed_current.flags = 1U;
  result = write_current_atomic_unlocked(directory_fd, current_name, &observed_current);

cleanup:
  return finish_state_directory_lock(directory_fd, result);
}

static int make_state_name(char *buffer, size_t buffer_size, const char *prefix,
                            const char *generation_hex, const char *run_hex) {
  const int formatted = run_hex == NULL
                            ? snprintf(buffer, buffer_size, "%s.%s", prefix, generation_hex)
                            : snprintf(buffer, buffer_size, "%s.%s.%s", prefix, generation_hex, run_hex);

  if (formatted < 0 || (size_t)formatted >= buffer_size) {
    errno = ENAMETOOLONG;
    return -1;
  }
  return 0;
}

static bool state_record_name_has_form(const char *name, const char *prefix, bool has_run_nonce) {
  const size_t prefix_length = strlen(prefix);
  const size_t expected_length = prefix_length + 1U + HEX_SIZE +
                                 (has_run_nonce ? 1U + HEX_SIZE : 0U);
  size_t index;

  if (strlen(name) != expected_length || memcmp(name, prefix, prefix_length) != 0 ||
      name[prefix_length] != '.') {
    return false;
  }
  for (index = 0U; index < HEX_SIZE; ++index) {
    if (hex_value((unsigned char)name[prefix_length + 1U + index]) < 0) {
      return false;
    }
  }
  if (!has_run_nonce || name[prefix_length + 1U + HEX_SIZE] != '.') {
    return !has_run_nonce;
  }
  for (index = 0U; index < HEX_SIZE; ++index) {
    if (hex_value((unsigned char)name[prefix_length + 2U + HEX_SIZE + index]) < 0) {
      return false;
    }
  }
  return true;
}

static bool is_final_state_record_name(const char *name) {
  static const char *const run_prefixes[] = {
    "waiting", "prepare", "ready-ack", "decision", "commit-ack", "abort-ack",
  };
  size_t index;

  if (state_record_name_has_form(name, "current", false)) {
    return true;
  }
  for (index = 0U; index < sizeof(run_prefixes) / sizeof(run_prefixes[0]); ++index) {
    if (state_record_name_has_form(name, run_prefixes[index], true)) {
      return true;
    }
  }
  return false;
}

static int prune_stale_state_records_unlocked(int directory_fd, const unsigned char generation[DIGEST_SIZE],
                                              const unsigned char run_nonce[DIGEST_SIZE]) {
  static const char *const prefixes[] = {
    "current", "waiting", "prepare", "ready-ack", "decision", "commit-ack", "abort-ack",
  };
  char generation_hex[HEX_SIZE + 1U];
  char run_hex[HEX_SIZE + 1U];
  char current_names[sizeof(prefixes) / sizeof(prefixes[0])][NAME_MAX + 1U];
  DIR *stream;
  struct dirent *entry;
  int scan_fd;
  size_t index;

  hex_encode_64(generation, generation_hex);
  hex_encode_64(run_nonce, run_hex);
  for (index = 0U; index < sizeof(prefixes) / sizeof(prefixes[0]); ++index) {
    if (make_state_name(current_names[index], sizeof(current_names[index]), prefixes[index], generation_hex,
                        index == 0U ? NULL : run_hex) != 0) {
      return -1;
    }
  }
  scan_fd = openat(directory_fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (scan_fd < 0) {
    return -1;
  }
  stream = fdopendir(scan_fd);
  if (stream == NULL) {
    const int saved_errno = errno;

    (void)close(scan_fd);
    errno = saved_errno;
    return -1;
  }
  for (;;) {
    bool preserve = false;

    errno = 0;
    entry = readdir(stream);
    if (entry == NULL) {
      if (errno != 0) {
        const int saved_errno = errno;

        (void)closedir(stream);
        errno = saved_errno;
        return -1;
      }
      break;
    }
    if (!is_final_state_record_name(entry->d_name)) {
      continue;
    }
    for (index = 0U; index < sizeof(current_names) / sizeof(current_names[0]); ++index) {
      if (strcmp(entry->d_name, current_names[index]) == 0) {
        preserve = true;
        break;
      }
    }
    if (!preserve && unlinkat(directory_fd, entry->d_name, 0) != 0) {
      const int saved_errno = errno;

      (void)closedir(stream);
      errno = saved_errno;
      return -1;
    }
  }
  if (closedir(stream) != 0 || fsync(directory_fd) != 0) {
    return -1;
  }
  return 0;
}

static int prune_stale_state_records(int directory_fd, const unsigned char generation[DIGEST_SIZE],
                                     const unsigned char run_nonce[DIGEST_SIZE]) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_EX) != 0) {
    return -1;
  }
  result = prune_stale_state_records_unlocked(directory_fd, generation, run_nonce);
  return finish_state_directory_lock(directory_fd, result);
}

static int load_active_state_unlocked(int directory_fd, const struct configuration *configuration,
                                      const unsigned char generation[DIGEST_SIZE], bool require_verified,
                                      struct active_state *active_out) {
  struct active_state active = { 0 };
  char current_name[NAME_MAX + 1U];
  char waiting_name[NAME_MAX + 1U];

  hex_encode_64(generation, active.generation_hex);
  if (make_state_name(current_name, sizeof(current_name), "current", active.generation_hex, NULL) != 0 ||
      read_record_at_unlocked(directory_fd, current_name, RECORD_CURRENT, &active.current) != 0 ||
      !constant_time_equal(active.current.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(active.current.config_digest, configuration->config_digest, DIGEST_SIZE) ||
      (require_verified && active.current.flags != 1U)) {
    errno = EPROTO;
    return -1;
  }
  hex_encode_64(active.current.run_nonce, active.run_hex);
  if (make_state_name(waiting_name, sizeof(waiting_name), "waiting", active.generation_hex,
                      active.run_hex) != 0 ||
      read_record_at_unlocked(directory_fd, waiting_name, RECORD_WAITING, &active.waiting) != 0 ||
      !constant_time_equal(active.waiting.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(active.waiting.run_nonce, active.current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(active.waiting.config_digest, configuration->config_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  *active_out = active;
  return 0;
}

static int load_active_state(int directory_fd, const struct configuration *configuration,
                             const unsigned char generation[DIGEST_SIZE], bool require_verified,
                             struct active_state *active_out) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = load_active_state_unlocked(directory_fd, configuration, generation, require_verified, active_out);
  return finish_state_directory_lock(directory_fd, result);
}

static int load_prepared_state_unlocked(int directory_fd, const struct configuration *configuration,
                                         const unsigned char generation[DIGEST_SIZE], bool require_verified,
                                         struct active_state *active_out, struct state_record *prepare_out,
                                         struct state_record *ready_out) {
  struct active_state active;
  char prepare_name[NAME_MAX + 1U];
  char ready_name[NAME_MAX + 1U];

  if (load_active_state_unlocked(directory_fd, configuration, generation, require_verified, &active) != 0 ||
      make_state_name(prepare_name, sizeof(prepare_name), "prepare", active.generation_hex,
                      active.run_hex) != 0 ||
      make_state_name(ready_name, sizeof(ready_name), "ready-ack", active.generation_hex,
                      active.run_hex) != 0 ||
      read_record_at_unlocked(directory_fd, prepare_name, RECORD_PREPARE, prepare_out) != 0 ||
      read_record_at_unlocked(directory_fd, ready_name, RECORD_READY_ACK, ready_out) != 0 ||
      !constant_time_equal(prepare_out->generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(prepare_out->run_nonce, active.current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(prepare_out->config_digest, configuration->config_digest, DIGEST_SIZE) ||
      !constant_time_equal(ready_out->generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(ready_out->run_nonce, active.current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(ready_out->config_digest, configuration->config_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  *active_out = active;
  return 0;
}

static int load_prepared_state(int directory_fd, const struct configuration *configuration,
                                const unsigned char generation[DIGEST_SIZE], bool require_verified,
                                struct active_state *active_out, struct state_record *prepare_out,
                                struct state_record *ready_out) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = load_prepared_state_unlocked(directory_fd, configuration, generation, require_verified, active_out,
                                        prepare_out, ready_out);
  return finish_state_directory_lock(directory_fd, result);
}

static int load_decision_record_unlocked(int directory_fd, const struct active_state *active,
                                         const struct configuration *configuration,
                                         struct state_record *decision_out) {
  char decision_name[NAME_MAX + 1U];

  if (make_state_name(decision_name, sizeof(decision_name), "decision", active->generation_hex,
                      active->run_hex) != 0) {
    return -1;
  }
  if (read_record_at_unlocked(directory_fd, decision_name, RECORD_DECISION, decision_out) != 0) {
    return -1;
  }
  if (
      !constant_time_equal(decision_out->generation, active->current.generation, DIGEST_SIZE) ||
      !constant_time_equal(decision_out->run_nonce, active->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(decision_out->config_digest, configuration->config_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int load_decision_record(int directory_fd, const struct active_state *active,
                                const struct configuration *configuration,
                                struct state_record *decision_out) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = load_decision_record_unlocked(directory_fd, active, configuration, decision_out);
  return finish_state_directory_lock(directory_fd, result);
}

static int record_digest(const struct state_record *record, unsigned char digest[DIGEST_SIZE]) {
  unsigned char serialized[RECORD_SIZE];

  record_serialize(record, serialized);
  sha256_bytes(serialized, sizeof(serialized), digest);
  return 0;
}

static int sleep_briefly(void) {
  const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000L };

  while (nanosleep(&delay, NULL) != 0) {
    if (errno != EINTR) {
      return -1;
    }
  }
  return 0;
}

static int random_bytes(unsigned char output[DIGEST_SIZE]) {
  size_t received = 0U;

  while (received < DIGEST_SIZE) {
    const ssize_t result = getrandom(output + received, DIGEST_SIZE - received, 0U);

    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (result == 0) {
      errno = EIO;
      return -1;
    }
    received += (size_t)result;
  }
  return 0;
}

static int validate_inherited_environment(const struct configuration *configuration) {
  struct sha256_context context;
  unsigned char digest[DIGEST_SIZE];
  size_t index;
  static const unsigned char separator = '\0';

  sha256_init(&context);
  for (index = 0U; environ[index] != NULL; ++index) {
    const size_t length = strlen(environ[index]);

    if (memchr(environ[index], '\0', length) != NULL) {
      errno = EPROTO;
      return -1;
    }
    sha256_update(&context, environ[index], length);
    sha256_update(&context, &separator, 1U);
  }
  sha256_final(&context, digest);
  if (!constant_time_equal(digest, configuration->environment_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int find_environment_path(const struct configuration *configuration, const char **path_out) {
  size_t index;

  for (index = 0U; index < configuration->environment.count; ++index) {
    const struct byte_string *item = &configuration->environment.items[index];

    if (item->length >= 5U && memcmp(item->bytes, "PATH=", 5U) == 0) {
      *path_out = (const char *)item->bytes + 5U;
      return 0;
    }
  }
  errno = EPROTO;
  return -1;
}

static int exec_detail_digest(const struct configuration *configuration, enum execution_mode mode,
                              unsigned char digest[DIGEST_SIZE]) {
  const char *path = NULL;
  struct sha256_context context;
  static const char slash_label[] = "slash";
  static const char path_label[] = "path";

  sha256_init(&context);
  if (mode == EXECUTION_SLASH) {
    sha256_update(&context, slash_label, sizeof(slash_label) - 1U);
    sha256_update(&context, configuration->argv.items[0].bytes, configuration->argv.items[0].length);
  } else {
    if (find_environment_path(configuration, &path) != 0) {
      return -1;
    }
    sha256_update(&context, path_label, sizeof(path_label) - 1U);
    sha256_update(&context, path, strlen(path));
  }
  sha256_final(&context, digest);
  return 0;
}

static int read_optional_record_at_unlocked(int directory_fd, const char *name,
                                            enum record_type expected_type,
                                            struct state_record *record_out, bool *present_out) {
  if (read_record_at_unlocked(directory_fd, name, expected_type, record_out) == 0) {
    *present_out = true;
    return 0;
  }
  if (errno == ENOENT) {
    *present_out = false;
    return 0;
  }
  return -1;
}

static int read_live_acknowledgements_unlocked(int directory_fd, const struct active_state *active,
                                               struct acknowledgement_set *acknowledgements_out) {
  struct acknowledgement_set acknowledgements = { 0 };
  char commit_name[NAME_MAX + 1U];
  char abort_name[NAME_MAX + 1U];

  if (make_state_name(commit_name, sizeof(commit_name), "commit-ack", active->generation_hex,
                      active->run_hex) != 0 ||
      make_state_name(abort_name, sizeof(abort_name), "abort-ack", active->generation_hex,
                      active->run_hex) != 0 ||
       read_optional_record_at_unlocked(directory_fd, commit_name, RECORD_COMMIT_ACK,
                                        &acknowledgements.commit, &acknowledgements.saw_commit) != 0 ||
       read_optional_record_at_unlocked(directory_fd, abort_name, RECORD_ABORT_ACK,
                                        &acknowledgements.abort, &acknowledgements.saw_abort) != 0) {
    return -1;
  }
  *acknowledgements_out = acknowledgements;
  return 0;
}

static int validate_ack_record(const struct state_record *acknowledgement,
                               const struct active_state *active,
                               const struct configuration *configuration,
                               const unsigned char decision_digest[DIGEST_SIZE]) {
  static const unsigned char zero[DIGEST_SIZE] = { 0 };

  if (!constant_time_equal(acknowledgement->generation, active->current.generation, DIGEST_SIZE) ||
      !constant_time_equal(acknowledgement->run_nonce, active->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(acknowledgement->config_digest, configuration->config_digest, DIGEST_SIZE) ||
      !constant_time_equal(acknowledgement->binding_digest, decision_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  if (acknowledgement->type == RECORD_ABORT_ACK) {
    if (acknowledgement->flags != 0U ||
        !constant_time_equal(acknowledgement->detail_digest, zero, DIGEST_SIZE)) {
      errno = EPROTO;
      return -1;
    }
    return 0;
  }
  if (acknowledgement->type == RECORD_COMMIT_ACK) {
    const enum execution_mode expected_mode =
        strchr((const char *)configuration->argv.items[0].bytes, '/') != NULL ? EXECUTION_SLASH : EXECUTION_PATH;
    unsigned char expected_detail[DIGEST_SIZE];

    if (exec_detail_digest(configuration, expected_mode, expected_detail) != 0 ||
        acknowledgement->flags != (uint32_t)expected_mode ||
        !constant_time_equal(acknowledgement->detail_digest, expected_detail, DIGEST_SIZE)) {
      errno = EPROTO;
      return -1;
    }
    return 0;
  }
  errno = EPROTO;
  return -1;
}

static int validate_acknowledgements(const struct acknowledgement_set *acknowledgements,
                                     const struct state_record *decision,
                                     const struct active_state *active,
                                     const struct configuration *configuration,
                                     bool *matching_acknowledgement_out) {
  unsigned char decision_digest[DIGEST_SIZE];

  if ((decision->flags != DECISION_COMMIT && decision->flags != DECISION_ABORT) ||
      (decision->flags == DECISION_COMMIT && active->current.flags != 1U) ||
      record_digest(decision, decision_digest) != 0 ||
      (acknowledgements->saw_commit &&
       validate_ack_record(&acknowledgements->commit, active, configuration, decision_digest) != 0) ||
      (acknowledgements->saw_abort &&
       validate_ack_record(&acknowledgements->abort, active, configuration, decision_digest) != 0) ||
      (acknowledgements->saw_commit && acknowledgements->saw_abort) ||
      (decision->flags == DECISION_COMMIT && acknowledgements->saw_abort) ||
      (decision->flags == DECISION_ABORT && acknowledgements->saw_commit)) {
    errno = EPROTO;
    return -1;
  }
  *matching_acknowledgement_out = decision->flags == DECISION_COMMIT
                                      ? acknowledgements->saw_commit
                                      : acknowledgements->saw_abort;
  return 0;
}

static int validate_live_acknowledgements_unlocked(int directory_fd, const struct state_record *decision,
                                                   const struct active_state *active,
                                                   const struct configuration *configuration,
                                                   bool *matching_acknowledgement_out) {
  struct acknowledgement_set acknowledgements;

  if (read_live_acknowledgements_unlocked(directory_fd, active, &acknowledgements) != 0 ||
      validate_acknowledgements(&acknowledgements, decision, active, configuration,
                                matching_acknowledgement_out) != 0) {
    return -1;
  }
  return 0;
}

static int validate_live_acknowledgements(int directory_fd, const struct state_record *decision,
                                          const struct active_state *active,
                                          const struct configuration *configuration,
                                          bool *matching_acknowledgement_out) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = validate_live_acknowledgements_unlocked(directory_fd, decision, active, configuration,
                                                    matching_acknowledgement_out);
  return finish_state_directory_lock(directory_fd, result);
}

static int reject_live_orphan_acknowledgements_unlocked(int directory_fd,
                                                         const struct active_state *active) {
  struct acknowledgement_set acknowledgements;

  if (read_live_acknowledgements_unlocked(directory_fd, active, &acknowledgements) != 0) {
    return -1;
  }
  if (acknowledgements.saw_commit || acknowledgements.saw_abort) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int reject_live_orphan_acknowledgements(int directory_fd, const struct active_state *active) {
  int result;

  if (lock_state_directory(directory_fd, LOCK_SH) != 0) {
    return -1;
  }
  result = reject_live_orphan_acknowledgements_unlocked(directory_fd, active);
  return finish_state_directory_lock(directory_fd, result);
}

static int exec_original(const struct configuration *configuration) {
  char **argv = NULL;
  size_t index;
  const char *argv_zero;

  if (configuration->argv.count == 0U || configuration->argv.count > SIZE_MAX / sizeof(*argv) - 1U) {
    errno = EPROTO;
    return -1;
  }
  argv = calloc(configuration->argv.count + 1U, sizeof(*argv));
  if (argv == NULL) {
    return -1;
  }
  for (index = 0U; index < configuration->argv.count; ++index) {
    argv[index] = (char *)configuration->argv.items[index].bytes;
  }
  argv_zero = argv[0];
  if (strchr(argv_zero, '/') != NULL) {
    execve(argv_zero, argv, environ);
  } else {
    const char *path;
    const char *cursor;
    int access_denied = 0;

    if (find_environment_path(configuration, &path) != 0) {
      free(argv);
      return -1;
    }
    cursor = path;
    for (;;) {
      const char *separator = strchr(cursor, ':');
      const size_t component_length = separator == NULL ? strlen(cursor) : (size_t)(separator - cursor);
      const size_t candidate_length = (component_length == 0U ? 1U : component_length) + 1U +
                                      strlen(argv_zero) + 1U;
      char *candidate = malloc(candidate_length);

      if (candidate == NULL) {
        free(argv);
        return -1;
      }
      if (component_length == 0U) {
        (void)snprintf(candidate, candidate_length, "./%s", argv_zero);
      } else {
        memcpy(candidate, cursor, component_length);
        candidate[component_length] = '/';
        memcpy(candidate + component_length + 1U, argv_zero, strlen(argv_zero) + 1U);
      }
      execve(candidate, argv, environ);
      if (errno == EACCES) {
        access_denied = 1;
      } else if (errno != ENOENT && errno != ENOTDIR) {
        const int saved_errno = errno;

        free(candidate);
        free(argv);
        errno = saved_errno;
        return -1;
      }
      free(candidate);
      if (separator == NULL) {
        free(argv);
        errno = access_denied != 0 ? EACCES : ENOENT;
        return -1;
      }
      cursor = separator + 1U;
    }
  }
  free(argv);
  return -1;
}

#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
static int wait_for_test_hook(struct parsed_cli *cli, const char *description) {
  unsigned char byte = 'R';
  int received;

  if (cli->test_ready_fd < 0) {
    return 0;
  }
  if (write_all(cli->test_ready_fd, &byte, 1U) != 0) {
    return fail_errno(description);
  }
  received = read_one_byte(cli->test_release_fd, &byte);
  if (received != 1) {
    if (received == 0) {
      errno = EIO;
    }
    return fail_errno(description);
  }
  if (close(cli->test_ready_fd) != 0 || close(cli->test_release_fd) != 0) {
    return fail_errno(description);
  }
  cli->test_ready_fd = -1;
  cli->test_release_fd = -1;
  return 0;
}
#endif

static int command_encode(const struct parsed_cli *cli) {
  struct configuration configuration = { 0 };
  struct string_vector entrypoint = { 0 };
  struct string_vector cmd = { 0 };
  size_t index;
  const unsigned char *path;
  size_t path_length;
  int result = -1;

  if (parse_hex_64(cli->generation_text, configuration.generation) != 0 ||
      parse_uint64_decimal(cli->expected_dev_text, &configuration.expected_dev) != 0 ||
      parse_uint64_decimal(cli->expected_ino_text, &configuration.expected_ino) != 0 ||
      configuration.expected_dev == 0U || configuration.expected_ino == 0U ||
      parse_json_vector(cli->entrypoint_json, &entrypoint) != 0 ||
      parse_json_vector(cli->cmd_json, &cmd) != 0 ||
      parse_json_vector(cli->environment_json, &configuration.environment) != 0) {
    errorf("invalid encode input");
    goto cleanup;
  }
  if (entrypoint.count != 0U) {
    for (index = 0U; index < entrypoint.count; ++index) {
      if (vector_append(&configuration.argv, entrypoint.items[index].bytes, entrypoint.items[index].length) != 0) {
        errorf("invalid entrypoint");
        goto cleanup;
      }
    }
  }
  for (index = 0U; index < cmd.count; ++index) {
    if (vector_append(&configuration.argv, cmd.items[index].bytes, cmd.items[index].length) != 0) {
      errorf("invalid command");
      goto cleanup;
    }
  }
  if (configuration.argv.count == 0U ||
      validate_environment(&configuration.environment, &path, &path_length) != 0) {
    errorf("invalid image command or environment");
    goto cleanup;
  }
  (void)path;
  (void)path_length;
  vector_digest(&configuration.argv, configuration.argv_digest);
  vector_digest(&configuration.environment, configuration.environment_digest);
  if (serialize_configuration(&configuration) != 0 || write_configuration_fd(cli->config_fd, &configuration) != 0) {
    (void)fail_errno("cannot write sidecar configuration");
    goto cleanup;
  }
  result = 0;

cleanup:
  vector_free(&entrypoint);
  vector_free(&cmd);
  configuration_free(&configuration);
  return result;
}

static int tar_octal(char *field, size_t field_size, uint64_t value) {
  char encoded[32];
  int written;

  if (field_size < 2U) {
    errno = EINVAL;
    return -1;
  }
  written = snprintf(encoded, sizeof(encoded), "%0*" PRIo64, (int)(field_size - 1U), value);
  if (written < 0 || (size_t)written != field_size - 1U) {
    errno = EOVERFLOW;
    return -1;
  }
  memcpy(field, encoded, field_size - 1U);
  field[field_size - 1U] = '\0';
  return 0;
}

static int write_tar_header(const char *name, mode_t mode, uint64_t size) {
  unsigned char header[512];
  unsigned int checksum = 0U;
  size_t index;

  if (strlen(name) > 99U) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memset(header, 0, sizeof(header));
  memcpy(header, name, strlen(name));
  if (tar_octal((char *)header + 100U, 8U, (uint64_t)mode) != 0 ||
      tar_octal((char *)header + 108U, 8U, 0U) != 0 || tar_octal((char *)header + 116U, 8U, 0U) != 0 ||
      tar_octal((char *)header + 124U, 12U, size) != 0 || tar_octal((char *)header + 136U, 12U, 0U) != 0) {
    return -1;
  }
  memset(header + 148U, ' ', 8U);
  header[156U] = '0';
  memcpy(header + 257U, "ustar", 5U);
  header[262U] = '\0';
  memcpy(header + 263U, "00", 2U);
  for (index = 0U; index < sizeof(header); ++index) {
    checksum += header[index];
  }
  if (tar_octal((char *)header + 148U, 8U, checksum) != 0) {
    return -1;
  }
  return write_all(STDOUT_FILENO, header, sizeof(header));
}

static int write_tar_fd(int file_descriptor, const char *name, mode_t mode, uint64_t size) {
  unsigned char buffer[8192];
  uint64_t remaining = size;
  unsigned char zeroes[512] = { 0 };

  if (write_tar_header(name, mode, size) != 0) {
    return -1;
  }
  while (remaining != 0U) {
    const size_t wanted = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
    ssize_t received;

    do {
      received = read(file_descriptor, buffer, wanted);
    } while (received < 0 && errno == EINTR);
    if (received <= 0) {
      if (received == 0) {
        errno = EPROTO;
      }
      return -1;
    }
    if (write_all(STDOUT_FILENO, buffer, (size_t)received) != 0) {
      return -1;
    }
    remaining -= (uint64_t)received;
  }
  if (size % 512U != 0U && write_all(STDOUT_FILENO, zeroes, 512U - (size % 512U)) != 0) {
    return -1;
  }
  return 0;
}

static int command_archive(const struct parsed_cli *cli) {
  struct configuration configuration = { 0 };
  struct stat executable_status;
  int executable_fd = -1;
  unsigned char zeroes[1024] = { 0 };
  int result = -1;

  if (read_configuration_fd(cli->config_fd, &configuration) != 0) {
    return fail_errno("invalid sidecar configuration");
  }
  executable_fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
  if (executable_fd < 0 || fstat(executable_fd, &executable_status) != 0 ||
      !S_ISREG(executable_status.st_mode) || executable_status.st_size < 0 ||
      lseek(executable_fd, 0, SEEK_SET) < 0 || lseek(cli->config_fd, 0, SEEK_SET) < 0 ||
      write_tar_fd(executable_fd, "ocsb-sidecar-gate/ocsb-sidecar-gate", 0555U,
                   (uint64_t)executable_status.st_size) != 0 ||
      write_tar_fd(cli->config_fd, "ocsb-sidecar-gate/config", 0600U,
                   (uint64_t)configuration.serialized_length) != 0 ||
      write_all(STDOUT_FILENO, zeroes, sizeof(zeroes)) != 0) {
    (void)fail_errno("cannot write sidecar archive");
    goto cleanup;
  }
  result = 0;

cleanup:
  if (executable_fd >= 0) {
    (void)close(executable_fd);
  }
  configuration_free(&configuration);
  return result;
}

static int verify_mount_identity(const struct configuration *configuration, const char *mount_path) {
  struct open_how how = {
    .flags = O_PATH | O_CLOEXEC | O_NOFOLLOW,
    .resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
  };
  struct stat status;
  int mount_fd = -1;

  if (validate_absolute_path(mount_path) != 0) {
    return -1;
  }
  mount_fd = (int)syscall(SYS_openat2, AT_FDCWD, mount_path, &how, sizeof(how));
  if (mount_fd < 0) {
    return -1;
  }
  if (fstat(mount_fd, &status) != 0) {
    const int saved_errno = errno;

    (void)close(mount_fd);
    errno = saved_errno;
    return -1;
  }
  if (!S_ISDIR(status.st_mode) || (uint64_t)status.st_dev != configuration->expected_dev ||
      (uint64_t)status.st_ino != configuration->expected_ino) {
    (void)close(mount_fd);
    errno = EPROTO;
    return -1;
  }
  if (close(mount_fd) != 0) {
    return -1;
  }
  return 0;
}

static int command_verify(const struct parsed_cli *cli) {
  struct state_directory directory = { .directory_fd = -1 };
  struct configuration configuration = { 0 };
  struct active_state active;
  char current_name[NAME_MAX + 1U];
  int result = -1;
  int verify_result;
  unsigned char generation[DIGEST_SIZE];

  if (parse_hex_64(cli->generation_text, generation) != 0 ||
      open_state_directory(cli->config_path, &directory) != 0 ||
      read_configuration_path(&directory, &configuration) != 0 ||
      !constant_time_equal(generation, configuration.generation, DIGEST_SIZE)) {
    (void)fail_errno("invalid sidecar verify state");
    goto cleanup;
  }
  hex_encode_64(generation, active.generation_hex);
  if (make_state_name(current_name, sizeof(current_name), "current", active.generation_hex, NULL) != 0) {
    (void)fail_errno("cannot publish verified sidecar state");
    goto cleanup;
  }
  for (;;) {
    int liveness_result;

    if (load_active_state(directory.directory_fd, &configuration, generation, false, &active) != 0) {
      (void)fail_errno("invalid sidecar verify state");
      goto cleanup;
    }
    liveness_result = active_waiting_is_live(directory.directory_fd, &active);
    if (liveness_result > 0) {
      if (sleep_briefly() != 0) {
        (void)fail_errno("cannot wait for selected sidecar run");
        goto cleanup;
      }
      continue;
    }
    if (liveness_result < 0) {
      (void)fail_errno("invalid selected sidecar run state");
      goto cleanup;
    }
    if (verify_mount_identity(&configuration, cli->mount_path) != 0) {
      (void)fail_errno("sidecar mount identity mismatch");
      goto cleanup;
    }
    verify_result = write_verified_current_if_same_run(directory.directory_fd, current_name, &active.current);
    if (verify_result == 0) {
      break;
    }
    if (verify_result < 0) {
      (void)fail_errno("cannot publish verified sidecar state");
      goto cleanup;
    }
  }
  printf("MOUNT-VERIFIED %s %s\n", active.generation_hex, active.run_hex);
  result = 0;

cleanup:
  configuration_free(&configuration);
  close_state_directory(&directory);
  return result;
}

static int validate_existing_record(int directory_fd, const char *name, enum record_type type,
                                    const struct state_record *expected) {
  struct state_record existing;
  unsigned char expected_serialized[RECORD_SIZE];
  unsigned char existing_serialized[RECORD_SIZE];

  if (read_record_at(directory_fd, name, type, &existing) != 0) {
    return -1;
  }
  record_serialize(expected, expected_serialized);
  record_serialize(&existing, existing_serialized);
  if (!constant_time_equal(expected_serialized, existing_serialized, sizeof(expected_serialized))) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int command_release(const struct parsed_cli *cli) {
  struct state_directory directory = { .directory_fd = -1 };
  struct configuration configuration = { 0 };
  struct active_state active;
  struct state_record prepare = { .type = RECORD_PREPARE };
  struct state_record ready;
  unsigned char generation[DIGEST_SIZE];
  char prepare_name[NAME_MAX + 1U];
  char ready_name[NAME_MAX + 1U];
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 || open_state_directory(cli->config_path, &directory) != 0 ||
      read_configuration_path(&directory, &configuration) != 0 ||
      !constant_time_equal(generation, configuration.generation, DIGEST_SIZE) ||
       load_active_state(directory.directory_fd, &configuration, generation, false, &active) != 0 ||
      make_state_name(prepare_name, sizeof(prepare_name), "prepare", active.generation_hex,
                      active.run_hex) != 0 ||
      make_state_name(ready_name, sizeof(ready_name), "ready-ack", active.generation_hex,
                      active.run_hex) != 0) {
    (void)fail_errno("invalid sidecar release state");
    goto cleanup;
  }
  memcpy(prepare.generation, generation, DIGEST_SIZE);
  memcpy(prepare.run_nonce, active.current.run_nonce, DIGEST_SIZE);
  memcpy(prepare.config_digest, configuration.config_digest, DIGEST_SIZE);
  if (write_record_new(directory.directory_fd, prepare_name, &prepare) != 0) {
    if (errno != EEXIST || validate_existing_record(directory.directory_fd, prepare_name, RECORD_PREPARE,
                                                     &prepare) != 0) {
      (void)fail_errno("cannot create sidecar prepare record");
      goto cleanup;
    }
  }
  for (;;) {
    const int ready_result = read_record_at(directory.directory_fd, ready_name, RECORD_READY_ACK, &ready);

    if (ready_result == 0) {
      if (!constant_time_equal(ready.generation, generation, DIGEST_SIZE) ||
          !constant_time_equal(ready.run_nonce, active.current.run_nonce, DIGEST_SIZE) ||
          !constant_time_equal(ready.config_digest, configuration.config_digest, DIGEST_SIZE)) {
        errno = EPROTO;
        (void)fail_errno("cannot wait for sidecar ready acknowledgement");
        goto cleanup;
      }
      break;
    }
    if (errno != ENOENT || sleep_briefly() != 0) {
      (void)fail_errno("cannot wait for sidecar ready acknowledgement");
      goto cleanup;
    }
  }
  printf("PREPARED %s %s\n", active.generation_hex, active.run_hex);
  result = 0;

cleanup:
  configuration_free(&configuration);
  close_state_directory(&directory);
  return result;
}

static int create_decision_cas_locked(int directory_fd, const struct active_state *active,
                                      const struct configuration *configuration,
                                      enum decision_value requested, struct parsed_cli *cli,
                                      struct state_record *winner_out) {
  struct state_record requested_record = { .type = RECORD_DECISION, .flags = (uint32_t)requested };
  unsigned char bytes[RECORD_SIZE];
  char decision_name[NAME_MAX + 1U];
  int file_descriptor;

#ifndef OCSB_SIDECAR_GATE_TEST_HOOKS
  (void)cli;
#endif
  memcpy(requested_record.generation, active->current.generation, DIGEST_SIZE);
  memcpy(requested_record.run_nonce, active->current.run_nonce, DIGEST_SIZE);
  memcpy(requested_record.config_digest, configuration->config_digest, DIGEST_SIZE);
  if (make_state_name(decision_name, sizeof(decision_name), "decision", active->generation_hex,
                      active->run_hex) != 0) {
    return -1;
  }
  record_serialize(&requested_record, bytes);
  file_descriptor = openat(directory_fd, decision_name,
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600U);
  if (file_descriptor >= 0) {
    if (fchmod(file_descriptor, 0600U) != 0 || write_all(file_descriptor, bytes, sizeof(bytes)) != 0 ||
        fsync(file_descriptor) != 0) {
      const int saved_errno = errno;

      (void)close(file_descriptor);
      errno = saved_errno;
      return -1;
    }
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
    if (wait_for_test_hook(cli, "test decision publication barrier") != 0) {
      const int saved_errno = errno;

      (void)close(file_descriptor);
      errno = saved_errno;
      return -1;
    }
#endif
    if (close(file_descriptor) != 0 || fsync(directory_fd) != 0) {
      return -1;
    }
    *winner_out = requested_record;
    return 0;
  }
  if (errno != EEXIST || load_decision_record_unlocked(directory_fd, active, configuration, winner_out) != 0) {
    return -1;
  }
  return 0;
}

static int command_decision_config(struct parsed_cli *cli) {
  struct state_directory directory = { .directory_fd = -1 };
  struct configuration configuration = { 0 };
  struct active_state active;
  struct state_record prepare;
  struct state_record ready;
  struct state_record decision;
  unsigned char generation[DIGEST_SIZE];
  bool matching_acknowledgement;
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 || open_state_directory(cli->config_path, &directory) != 0 ||
      read_configuration_path(&directory, &configuration) != 0 ||
      !constant_time_equal(generation, configuration.generation, DIGEST_SIZE) ||
       load_prepared_state(directory.directory_fd, &configuration, generation, false, &active, &prepare,
                           &ready) != 0) {
    (void)fail_errno("invalid sidecar decision state");
    goto cleanup;
  }
  if (cli->query) {
    if (load_decision_record(directory.directory_fd, &active, &configuration, &decision) != 0) {
      if (errno != ENOENT) {
        (void)fail_errno("invalid sidecar decision record");
        goto cleanup;
      }
      if (reject_live_orphan_acknowledgements(directory.directory_fd, &active) != 0) {
        (void)fail_errno("invalid sidecar acknowledgement state");
        goto cleanup;
      }
      printf("DECISION absent %s %s\n", active.generation_hex, active.run_hex);
    } else {
      if (validate_live_acknowledgements(directory.directory_fd, &decision, &active, &configuration,
                                         &matching_acknowledgement) != 0) {
        (void)fail_errno("invalid sidecar acknowledgement state");
        goto cleanup;
      }
      printf("DECISION %s %s %s\n", decision.flags == DECISION_COMMIT ? "commit" : "abort",
             active.generation_hex, active.run_hex);
    }
  } else {
    int decision_result;

    if (lock_state_directory(directory.directory_fd, LOCK_EX) != 0) {
      (void)fail_errno("cannot create sidecar decision");
      goto cleanup;
    }
    if (load_prepared_state_unlocked(directory.directory_fd, &configuration, generation, false, &active,
                                     &prepare, &ready) != 0 ||
        (cli->decision == DECISION_COMMIT && active.current.flags != 1U)) {
      decision_result = -1;
    } else if (load_decision_record_unlocked(directory.directory_fd, &active, &configuration, &decision) == 0) {
      decision_result = validate_live_acknowledgements_unlocked(directory.directory_fd, &decision, &active,
                                                                 &configuration, &matching_acknowledgement);
    } else if (errno != ENOENT ||
               reject_live_orphan_acknowledgements_unlocked(directory.directory_fd, &active) != 0) {
      decision_result = -1;
    } else if (create_decision_cas_locked(directory.directory_fd, &active, &configuration, cli->decision, cli,
                                          &decision) != 0 ||
               validate_live_acknowledgements_unlocked(directory.directory_fd, &decision, &active,
                                                       &configuration, &matching_acknowledgement) != 0) {
      decision_result = -1;
    } else {
      decision_result = 0;
    }
    if (finish_state_directory_lock(directory.directory_fd, decision_result) != 0) {
      (void)fail_errno("cannot create sidecar decision");
      goto cleanup;
    }
    printf("DECISION %s %s %s\n", decision.flags == DECISION_COMMIT ? "commit" : "abort",
           active.generation_hex, active.run_hex);
  }
  result = 0;

cleanup:
  configuration_free(&configuration);
  close_state_directory(&directory);
  return result;
}

static int read_tar_octal(const unsigned char *field, size_t field_size, uint64_t *value_out) {
  uint64_t value = 0U;
  size_t index = 0U;
  bool saw_digit = false;

  while (index < field_size && (field[index] == ' ' || field[index] == '\0')) {
    ++index;
  }
  for (; index < field_size && field[index] >= '0' && field[index] <= '7'; ++index) {
    const unsigned int digit = (unsigned int)(field[index] - '0');

    if (value > (UINT64_MAX - digit) / 8U) {
      return -1;
    }
    value = value * 8U + digit;
    saw_digit = true;
  }
  while (index < field_size) {
    if (field[index] != ' ' && field[index] != '\0') {
      return -1;
    }
    ++index;
  }
  if (!saw_digit) {
    return -1;
  }
  *value_out = value;
  return 0;
}

static bool tar_block_is_zero(const unsigned char block[512]) {
  size_t index;

  for (index = 0U; index < 512U; ++index) {
    if (block[index] != 0U) {
      return false;
    }
  }
  return true;
}

static bool bytes_are_zero(const unsigned char *bytes, size_t length) {
  size_t index;

  for (index = 0U; index < length; ++index) {
    if (bytes[index] != 0U) {
      return false;
    }
  }
  return true;
}

static int tar_zero_field(const unsigned char *field, size_t field_size) {
  uint64_t value;

  if (bytes_are_zero(field, field_size)) {
    return 0;
  }
  if (read_tar_octal(field, field_size, &value) != 0 || value != 0U) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int tar_validate_checksum(const unsigned char header[512]) {
  uint64_t expected;
  unsigned int actual = 0U;
  size_t index;

  if (read_tar_octal(header + 148U, 8U, &expected) != 0 || expected > UINT_MAX) {
    return -1;
  }
  for (index = 0U; index < 512U; ++index) {
    actual += (index >= 148U && index < 156U) ? (unsigned int)' ' : header[index];
  }
  return actual == (unsigned int)expected ? 0 : -1;
}

static int tar_name(const unsigned char header[512], char output[256]) {
  size_t name_length = strnlen((const char *)header, 100U);
  size_t prefix_length = strnlen((const char *)header + 345U, 155U);

  if (name_length == 100U || prefix_length == 155U || name_length == 0U ||
      prefix_length + (prefix_length == 0U ? 0U : 1U) + name_length >= 256U) {
    return -1;
  }
  if (prefix_length != 0U) {
    memcpy(output, header + 345U, prefix_length);
    output[prefix_length] = '/';
    memcpy(output + prefix_length + 1U, header, name_length);
    output[prefix_length + 1U + name_length] = '\0';
  } else {
    memcpy(output, header, name_length);
    output[name_length] = '\0';
  }
  return 0;
}

static int consume_tar_bytes(int file_descriptor, uint64_t size, unsigned char **copy_out,
                             size_t copy_limit) {
  unsigned char *copy = NULL;
  unsigned char buffer[8192];
  uint64_t remaining = size;
  uint64_t padding;

  if (size > copy_limit && copy_out != NULL) {
    errno = EOVERFLOW;
    return -1;
  }
  if (copy_out != NULL) {
    copy = malloc((size_t)size == 0U ? 1U : (size_t)size);
    if (copy == NULL) {
      return -1;
    }
  }
  while (remaining != 0U) {
    const size_t wanted = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
    const size_t offset = (size_t)(size - remaining);

    if (read_all_exact(file_descriptor, buffer, wanted) != 0) {
      free(copy);
      return -1;
    }
    if (copy != NULL) {
      memcpy(copy + offset, buffer, wanted);
    }
    remaining -= wanted;
  }
  padding = (512U - (size % 512U)) % 512U;
  if (padding != 0U) {
    if (read_all_exact(file_descriptor, buffer, (size_t)padding) != 0 ||
        !bytes_are_zero(buffer, (size_t)padding)) {
      free(copy);
      errno = EPROTO;
      return -1;
    }
  }
  if (copy_out != NULL) {
    *copy_out = copy;
  }
  return 0;
}

static int parse_pax_path(const unsigned char *bytes, size_t length, char path_out[PATH_MAX]) {
  size_t offset = 0U;
  bool saw_path = false;

  while (offset < length) {
    size_t cursor = offset;
    size_t record_length = 0U;
    size_t payload_start;
    size_t record_end;
    size_t path_length;

    if (bytes[cursor] < '0' || bytes[cursor] > '9') {
      errno = EPROTO;
      return -1;
    }
    do {
      const unsigned int digit = (unsigned int)(bytes[cursor] - '0');

      if (record_length > (SIZE_MAX - digit) / 10U) {
        errno = EPROTO;
        return -1;
      }
      record_length = record_length * 10U + digit;
      ++cursor;
    } while (cursor < length && bytes[cursor] >= '0' && bytes[cursor] <= '9');
    if (cursor == length || bytes[cursor] != ' ' || record_length <= cursor - offset + 1U ||
        record_length > length - offset) {
      errno = EPROTO;
      return -1;
    }
    payload_start = cursor + 1U;
    record_end = offset + record_length;
    if (bytes[record_end - 1U] != '\n' || record_end - payload_start < 6U ||
        memcmp(bytes + payload_start, "path=", 5U) != 0 || saw_path) {
      errno = EPROTO;
      return -1;
    }
    path_length = record_end - payload_start - 6U;
    if (path_length == 0U || path_length >= PATH_MAX ||
        memchr(bytes + payload_start + 5U, '\0', path_length) != NULL) {
      errno = EPROTO;
      return -1;
    }
    memcpy(path_out, bytes + payload_start + 5U, path_length);
    path_out[path_length] = '\0';
    saw_path = true;
    offset = record_end;
  }
  if (!saw_path) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int archive_record_name(const char *name, const struct state_record *record) {
  char generation_hex[HEX_SIZE + 1U];
  char run_hex[HEX_SIZE + 1U];
  char expected[NAME_MAX + 1U];
  const char *prefix = NULL;

  switch (record->type) {
    case RECORD_WAITING: prefix = "waiting"; break;
    case RECORD_CURRENT: prefix = "current"; break;
    case RECORD_PREPARE: prefix = "prepare"; break;
    case RECORD_READY_ACK: prefix = "ready-ack"; break;
    case RECORD_DECISION: prefix = "decision"; break;
    case RECORD_COMMIT_ACK: prefix = "commit-ack"; break;
    case RECORD_ABORT_ACK: prefix = "abort-ack"; break;
  }
  if (prefix == NULL) {
    errno = EPROTO;
    return -1;
  }
  hex_encode_64(record->generation, generation_hex);
  hex_encode_64(record->run_nonce, run_hex);
  if (make_state_name(expected, sizeof(expected), prefix, generation_hex,
                      record->type == RECORD_CURRENT ? NULL : run_hex) != 0) {
    return -1;
  }
  return strcmp(name, expected) == 0 ? 0 : -1;
}

static int archive_store_record(struct archive_state *archive, const char *name,
                                const unsigned char bytes[RECORD_SIZE],
                                const unsigned char requested_generation[DIGEST_SIZE]) {
  struct state_record record;
  struct state_record *expanded;
  size_t next_capacity;

  if (record_deserialize(bytes, &record) != 0 || validate_record_shape(&record) != 0 ||
      archive_record_name(name, &record) != 0) {
    errno = EPROTO;
    return -1;
  }
  if (!constant_time_equal(record.generation, requested_generation, DIGEST_SIZE)) {
    return 0;
  }
  if (archive->record_count == archive->record_capacity) {
    next_capacity = archive->record_capacity == 0U ? 16U : archive->record_capacity * 2U;
    if (next_capacity < archive->record_capacity || next_capacity > MAX_ARCHIVE_ENTRIES ||
        next_capacity > SIZE_MAX / sizeof(*expanded)) {
      errno = EOVERFLOW;
      return -1;
    }
    expanded = realloc(archive->records, next_capacity * sizeof(*expanded));
    if (expanded == NULL) {
      return -1;
    }
    archive->records = expanded;
    archive->record_capacity = next_capacity;
  }
  archive->records[archive->record_count++] = record;
  return 0;
}

static int archive_materialize_current_records(struct archive_state *archive) {
  size_t index;

  for (index = 0U; index < archive->record_count; ++index) {
    const struct state_record *record = &archive->records[index];

    if (record->type == RECORD_CURRENT) {
      if (archive->saw_current) {
        errno = EPROTO;
        return -1;
      }
      archive->current = *record;
      archive->saw_current = true;
    }
  }
  if (!archive->saw_current) {
    errno = EPROTO;
    return -1;
  }
  for (index = 0U; index < archive->record_count; ++index) {
    const struct state_record *record = &archive->records[index];
    struct state_record *slot = NULL;
    bool *seen = NULL;

    if (record->type == RECORD_CURRENT ||
        !constant_time_equal(record->run_nonce, archive->current.run_nonce, DIGEST_SIZE)) {
      continue;
    }
    switch (record->type) {
      case RECORD_WAITING: slot = &archive->waiting; seen = &archive->saw_waiting; break;
      case RECORD_PREPARE: slot = &archive->prepare; seen = &archive->saw_prepare; break;
      case RECORD_READY_ACK: slot = &archive->ready_ack; seen = &archive->saw_ready_ack; break;
      case RECORD_DECISION: slot = &archive->decision; seen = &archive->saw_decision; break;
      case RECORD_COMMIT_ACK: slot = &archive->commit_ack; seen = &archive->saw_commit_ack; break;
      case RECORD_ABORT_ACK: slot = &archive->abort_ack; seen = &archive->saw_abort_ack; break;
      case RECORD_CURRENT: break;
    }
    if (seen == NULL || *seen) {
      errno = EPROTO;
      return -1;
    }
    *slot = *record;
    *seen = true;
  }
  return 0;
}

static int parse_state_archive(int file_descriptor, struct archive_state *archive,
                               const unsigned char requested_generation[DIGEST_SIZE]) {
  unsigned char header[512];
  char pending_path[PATH_MAX];
  size_t entry_count = 0U;
  bool saw_end = false;
  bool has_pending_path = false;

  for (;;) {
    char header_name[256];
    char name[PATH_MAX];
    uint64_t size;
    uint64_t mode;
    unsigned char type;
    int received;

    received = read_one_byte(file_descriptor, header);
    if (received == 0) {
      break;
    }
    if (received < 0 || read_all_exact(file_descriptor, header + 1U, sizeof(header) - 1U) != 0) {
      return -1;
    }
    if (tar_block_is_zero(header)) {
      if (read_all_exact(file_descriptor, header, sizeof(header)) != 0 || !tar_block_is_zero(header)) {
        errno = EPROTO;
        return -1;
      }
      saw_end = true;
      break;
    }
    if (++entry_count > MAX_ARCHIVE_ENTRIES || tar_validate_checksum(header) != 0 ||
        memcmp(header + 257U, "ustar", 5U) != 0 ||
        !((header[262U] == '\0' && header[263U] == '0' && header[264U] == '0') ||
          (header[262U] == ' ' && header[263U] == ' ' && header[264U] == '\0')) ||
        tar_name(header, header_name) != 0 ||
        !bytes_are_zero(header + 157U, 100U) ||
        read_tar_octal(header + 100U, 8U, &mode) != 0 ||
        read_tar_octal(header + 124U, 12U, &size) != 0 || size > MAX_ARCHIVE_FILE_SIZE ||
        tar_zero_field(header + 329U, 8U) != 0 || tar_zero_field(header + 337U, 8U) != 0) {
      errno = EPROTO;
      return -1;
    }
    type = header[156U];
    if (type == 'L') {
      unsigned char *long_name = NULL;

      if (has_pending_path || strcmp(header_name, "././@LongLink") != 0 || size == 0U ||
          size >= sizeof(pending_path) ||
          consume_tar_bytes(file_descriptor, size, &long_name, sizeof(pending_path) - 1U) != 0 ||
          long_name[size - 1U] != '\0' || memchr(long_name, '\0', (size_t)size - 1U) != NULL) {
        free(long_name);
        errno = EPROTO;
        return -1;
      }
      memcpy(pending_path, long_name, (size_t)size);
      free(long_name);
      has_pending_path = true;
      continue;
    }
    if (type == 'x') {
      unsigned char *pax = NULL;

      if (has_pending_path || size == 0U || size > (uint64_t)PATH_MAX + 64U ||
          consume_tar_bytes(file_descriptor, size, &pax, (size_t)PATH_MAX + 64U) != 0 ||
          parse_pax_path(pax, (size_t)size, pending_path) != 0) {
        free(pax);
        errno = EPROTO;
        return -1;
      }
      free(pax);
      has_pending_path = true;
      continue;
    }
    if (has_pending_path && type != '0' && type != '\0') {
      errno = EPROTO;
      return -1;
    }
    if (has_pending_path) {
      memcpy(name, pending_path, strlen(pending_path) + 1U);
      has_pending_path = false;
    } else {
      memcpy(name, header_name, strlen(header_name) + 1U);
    }
    if (type == '5') {
      if ((strcmp(name, "ocsb-sidecar-gate") != 0 && strcmp(name, "ocsb-sidecar-gate/") != 0) ||
          size != 0U || archive->saw_root ||
          consume_tar_bytes(file_descriptor, size, NULL, 0U) != 0) {
        errno = EPROTO;
        return -1;
      }
      archive->saw_root = true;
      continue;
    }
    if (type != '0' && type != '\0') {
      errno = EPROTO;
      return -1;
    }
    if (strcmp(name, "ocsb-sidecar-gate/ocsb-sidecar-gate") == 0) {
      if (archive->saw_binary || mode != 0555U || size == 0U ||
          consume_tar_bytes(file_descriptor, size, NULL, 0U) != 0) {
        errno = EPROTO;
        return -1;
      }
      archive->saw_binary = true;
    } else if (strcmp(name, "ocsb-sidecar-gate/config") == 0) {
      if (archive->config_bytes != NULL || mode != 0600U || size > MAX_CONFIG_SIZE ||
          consume_tar_bytes(file_descriptor, size, &archive->config_bytes, MAX_CONFIG_SIZE) != 0) {
        errno = EPROTO;
        return -1;
      }
      archive->config_length = (size_t)size;
    } else if (strncmp(name, "ocsb-sidecar-gate/", 18U) == 0 && mode == 0600U && size == RECORD_SIZE) {
      unsigned char *record_bytes = NULL;

      if (consume_tar_bytes(file_descriptor, size, &record_bytes, RECORD_SIZE) != 0 ||
          archive_store_record(archive, name + 18U, record_bytes, requested_generation) != 0) {
        free(record_bytes);
        errno = EPROTO;
        return -1;
      }
      free(record_bytes);
    } else {
      errno = EPROTO;
      return -1;
    }
  }
  if (!saw_end) {
    errno = EPROTO;
    return -1;
  }
  if (has_pending_path) {
    errno = EPROTO;
    return -1;
  }
  if (archive_materialize_current_records(archive) != 0) {
    return -1;
  }
  for (;;) {
    int received = read_one_byte(file_descriptor, header);

    if (received < 0) {
      return -1;
    }
    if (received == 0) {
      return 0;
    }
    if (read_all_exact(file_descriptor, header + 1U, sizeof(header) - 1U) != 0 ||
        !tar_block_is_zero(header)) {
      errno = EPROTO;
      return -1;
    }
  }
}

static int archive_find_active(const struct archive_state *archive, const struct configuration *configuration,
                               const unsigned char generation[DIGEST_SIZE], struct active_state *active_out) {
  struct active_state active;

  if (!archive->saw_current || !archive->saw_waiting || !archive->saw_prepare || !archive->saw_ready_ack ||
      !constant_time_equal(archive->current.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(archive->current.config_digest, configuration->config_digest, DIGEST_SIZE) ||
       !constant_time_equal(archive->waiting.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(archive->waiting.run_nonce, archive->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(archive->waiting.config_digest, configuration->config_digest, DIGEST_SIZE) ||
      !constant_time_equal(archive->prepare.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(archive->prepare.run_nonce, archive->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(archive->prepare.config_digest, configuration->config_digest, DIGEST_SIZE) ||
      !constant_time_equal(archive->ready_ack.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(archive->ready_ack.run_nonce, archive->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(archive->ready_ack.config_digest, configuration->config_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    return -1;
  }
  active.current = archive->current;
  active.waiting = archive->waiting;
  hex_encode_64(generation, active.generation_hex);
  hex_encode_64(active.current.run_nonce, active.run_hex);
  *active_out = active;
  return 0;
}

static int validate_archive_decision_and_acknowledgements(const struct archive_state *archive,
                                                          const struct active_state *active,
                                                          const struct configuration *configuration,
                                                          bool *matching_acknowledgement_out) {
  struct acknowledgement_set acknowledgements = {
    .saw_commit = archive->saw_commit_ack,
    .saw_abort = archive->saw_abort_ack,
    .commit = archive->commit_ack,
    .abort = archive->abort_ack,
  };

  if (!archive->saw_decision) {
    if (acknowledgements.saw_commit || acknowledgements.saw_abort) {
      errno = EPROTO;
      return -1;
    }
    *matching_acknowledgement_out = false;
    return 0;
  }
  if (!constant_time_equal(archive->decision.generation, active->current.generation, DIGEST_SIZE) ||
      !constant_time_equal(archive->decision.run_nonce, active->current.run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(archive->decision.config_digest, configuration->config_digest, DIGEST_SIZE) ||
      validate_acknowledgements(&acknowledgements, &archive->decision, active, configuration,
                                matching_acknowledgement_out) != 0) {
    errno = EPROTO;
    return -1;
  }
  return 0;
}

static int command_decision_archive(const struct parsed_cli *cli) {
  struct archive_state archive = { 0 };
  struct configuration configuration = { 0 };
  struct active_state active;
  unsigned char generation[DIGEST_SIZE];
  bool matching_acknowledgement;
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 ||
      parse_state_archive(cli->state_archive_fd, &archive, generation) != 0 || !archive.saw_binary ||
      archive.config_bytes == NULL ||
      decode_configuration_bytes(archive.config_bytes, archive.config_length, &configuration) != 0 ||
       !constant_time_equal(configuration.generation, generation, DIGEST_SIZE) ||
       archive_find_active(&archive, &configuration, generation, &active) != 0 ||
       validate_archive_decision_and_acknowledgements(&archive, &active, &configuration,
                                                      &matching_acknowledgement) != 0) {
    (void)fail_errno("invalid sidecar state archive");
    goto cleanup;
  }
  if (!archive.saw_decision) {
    printf("DECISION absent %s %s\n", active.generation_hex, active.run_hex);
  } else {
    printf("DECISION %s %s %s\n", archive.decision.flags == DECISION_COMMIT ? "commit" : "abort",
           active.generation_hex, active.run_hex);
  }
  result = 0;

cleanup:
  free(archive.config_bytes);
  free(archive.records);
  configuration_free(&configuration);
  return result;
}

static int command_ack_config(struct parsed_cli *cli) {
  struct state_directory directory = { .directory_fd = -1 };
  struct configuration configuration = { 0 };
  struct active_state active;
  struct state_record prepare;
  struct state_record ready;
  struct state_record decision;
  unsigned char generation[DIGEST_SIZE];
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 || open_state_directory(cli->config_path, &directory) != 0 ||
       read_configuration_path(&directory, &configuration) != 0 ||
       !constant_time_equal(generation, configuration.generation, DIGEST_SIZE) ||
       load_prepared_state(directory.directory_fd, &configuration, generation, false, &active, &prepare,
                           &ready) != 0 ||
       load_decision_record(directory.directory_fd, &active, &configuration, &decision) != 0) {
    (void)fail_errno("invalid sidecar acknowledgement state");
    goto cleanup;
  }
  if (decision.flags != (uint32_t)cli->decision) {
    errno = EPROTO;
    (void)fail_errno("invalid sidecar acknowledgement state");
    goto cleanup;
  }
  for (;;) {
    bool matching_acknowledgement;

    if (validate_live_acknowledgements(directory.directory_fd, &decision, &active, &configuration,
                                       &matching_acknowledgement) != 0) {
      (void)fail_errno("cannot wait for sidecar acknowledgement");
      goto cleanup;
    }
    if (matching_acknowledgement) {
      break;
    }
    if (sleep_briefly() != 0) {
      (void)fail_errno("cannot wait for sidecar acknowledgement");
      goto cleanup;
    }
  }
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
  if (cli->decision == DECISION_COMMIT && wait_for_test_hook(cli, "test acknowledgement barrier") != 0) {
    goto cleanup;
  }
#endif
  result = 0;

cleanup:
  configuration_free(&configuration);
  close_state_directory(&directory);
  return result;
}

static int command_ack_archive(const struct parsed_cli *cli) {
  struct archive_state archive = { 0 };
  struct configuration configuration = { 0 };
  struct active_state active;
  unsigned char generation[DIGEST_SIZE];
  bool matching_acknowledgement;
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 ||
       parse_state_archive(cli->state_archive_fd, &archive, generation) != 0 || !archive.saw_binary ||
       archive.config_bytes == NULL ||
       decode_configuration_bytes(archive.config_bytes, archive.config_length, &configuration) != 0 ||
       !constant_time_equal(configuration.generation, generation, DIGEST_SIZE) ||
       archive_find_active(&archive, &configuration, generation, &active) != 0 || !archive.saw_decision ||
       validate_archive_decision_and_acknowledgements(&archive, &active, &configuration,
                                                      &matching_acknowledgement) != 0) {
    (void)fail_errno("invalid sidecar archive acknowledgement state");
    goto cleanup;
  }
  if (archive.decision.flags != (uint32_t)cli->decision || !matching_acknowledgement) {
    errno = EPROTO;
    (void)fail_errno("invalid sidecar archive acknowledgement state");
    goto cleanup;
  }
  result = 0;

cleanup:
  free(archive.config_bytes);
  free(archive.records);
  configuration_free(&configuration);
  return result;
}

static int command_run(struct parsed_cli *cli) {
  struct state_directory directory = { .directory_fd = -1 };
  struct configuration configuration = { 0 };
  struct state_record waiting = { .type = RECORD_WAITING };
  struct state_record current = { .type = RECORD_CURRENT };
  struct state_record prepare;
  struct state_record ready = { .type = RECORD_READY_ACK };
  struct state_record decision;
  struct state_record verified_current;
  struct state_record acknowledgement;
  struct state_record startup_decision;
  struct active_state active;
  unsigned char generation[DIGEST_SIZE];
  unsigned char run_nonce[DIGEST_SIZE];
  unsigned char decision_digest[DIGEST_SIZE];
  unsigned char execution_detail[DIGEST_SIZE];
  char generation_hex[HEX_SIZE + 1U];
  char run_hex[HEX_SIZE + 1U];
  char waiting_name[NAME_MAX + 1U];
  char current_name[NAME_MAX + 1U];
  char prepare_name[NAME_MAX + 1U];
  char ready_name[NAME_MAX + 1U];
  char decision_name[NAME_MAX + 1U];
  char acknowledgement_name[NAME_MAX + 1U];
  enum execution_mode execution_mode;
  struct stat current_status;
  bool startup_matching_acknowledgement = false;
  bool resumed_run = false;
  int waiting_liveness_fd = -1;
  int result = -1;

  if (parse_hex_64(cli->generation_text, generation) != 0 || open_state_directory(cli->config_path, &directory) != 0 ||
      read_configuration_path(&directory, &configuration) != 0 ||
      !constant_time_equal(generation, configuration.generation, DIGEST_SIZE) ||
      validate_inherited_environment(&configuration) != 0) {
    (void)fail_errno("invalid sidecar run configuration");
    goto cleanup;
  }
  hex_encode_64(generation, generation_hex);
  if (make_state_name(current_name, sizeof(current_name), "current", generation_hex, NULL) != 0) {
    (void)fail_errno("cannot create sidecar state name");
    goto cleanup;
  }
  if (fstatat(directory.directory_fd, current_name, &current_status, AT_SYMLINK_NOFOLLOW) == 0) {
    if (load_active_state(directory.directory_fd, &configuration, generation, false, &active) != 0) {
      (void)fail_errno("cannot resume sidecar run state");
      goto cleanup;
    }
    if (load_decision_record(directory.directory_fd, &active, &configuration, &startup_decision) == 0) {
      if (validate_live_acknowledgements(directory.directory_fd, &startup_decision, &active, &configuration,
                                         &startup_matching_acknowledgement) != 0) {
        (void)fail_errno("cannot validate resumable sidecar decision state");
        goto cleanup;
      }
      if (startup_decision.flags == DECISION_ABORT && startup_matching_acknowledgement) {
        if (random_bytes(run_nonce) != 0) {
          (void)fail_errno("cannot create sidecar run nonce after terminal abort");
          goto cleanup;
        }
      } else {
        waiting = active.waiting;
        current = active.current;
        memcpy(run_nonce, active.current.run_nonce, DIGEST_SIZE);
        resumed_run = true;
      }
    } else if (errno == ENOENT) {
      if (reject_live_orphan_acknowledgements(directory.directory_fd, &active) != 0) {
        (void)fail_errno("cannot resume sidecar run with orphan acknowledgement");
        goto cleanup;
      }
      waiting = active.waiting;
      current = active.current;
      memcpy(run_nonce, active.current.run_nonce, DIGEST_SIZE);
      resumed_run = true;
    } else {
      (void)fail_errno("cannot validate resumable sidecar decision state");
      goto cleanup;
    }
  } else if (errno == ENOENT) {
    if (random_bytes(run_nonce) != 0) {
      (void)fail_errno("cannot create sidecar run nonce");
      goto cleanup;
    }
  } else {
    (void)fail_errno("cannot inspect sidecar run state");
    goto cleanup;
  }
  hex_encode_64(run_nonce, run_hex);
  if (make_state_name(waiting_name, sizeof(waiting_name), "waiting", generation_hex, run_hex) != 0 ||
      make_state_name(prepare_name, sizeof(prepare_name), "prepare", generation_hex, run_hex) != 0 ||
      make_state_name(ready_name, sizeof(ready_name), "ready-ack", generation_hex, run_hex) != 0 ||
      make_state_name(decision_name, sizeof(decision_name), "decision", generation_hex, run_hex) != 0 ||
      make_state_name(acknowledgement_name, sizeof(acknowledgement_name), "commit-ack", generation_hex,
                      run_hex) != 0) {
    (void)fail_errno("cannot create sidecar state name");
    goto cleanup;
  }
  if (!resumed_run) {
    memcpy(waiting.generation, generation, DIGEST_SIZE);
    memcpy(waiting.run_nonce, run_nonce, DIGEST_SIZE);
    memcpy(waiting.config_digest, configuration.config_digest, DIGEST_SIZE);
    current = waiting;
    current.type = RECORD_CURRENT;
    if (write_record_new(directory.directory_fd, waiting_name, &waiting) != 0 ||
        write_current_atomic(directory.directory_fd, current_name, &current) != 0) {
      (void)fail_errno("cannot publish sidecar waiting state");
      goto cleanup;
    }
  }
  if (prune_stale_state_records(directory.directory_fd, generation, run_nonce) != 0) {
    (void)fail_errno("cannot retire stale sidecar run state");
    goto cleanup;
  }
  waiting_liveness_fd = open_waiting_liveness(directory.directory_fd, waiting_name, &waiting);
  if (waiting_liveness_fd < 0) {
    (void)fail_errno("cannot publish selected sidecar run state");
    goto cleanup;
  }
  for (;;) {
    const int prepare_result = read_record_at(directory.directory_fd, prepare_name, RECORD_PREPARE, &prepare);

    if (prepare_result == 0) {
      if (!constant_time_equal(prepare.generation, generation, DIGEST_SIZE) ||
          !constant_time_equal(prepare.run_nonce, run_nonce, DIGEST_SIZE) ||
          !constant_time_equal(prepare.config_digest, configuration.config_digest, DIGEST_SIZE)) {
        errno = EPROTO;
        (void)fail_errno("cannot wait for sidecar prepare");
        goto cleanup;
      }
      break;
    }
    if (errno != ENOENT || sleep_briefly() != 0) {
      (void)fail_errno("cannot wait for sidecar prepare");
      goto cleanup;
    }
  }
  memcpy(ready.generation, generation, DIGEST_SIZE);
  memcpy(ready.run_nonce, run_nonce, DIGEST_SIZE);
  memcpy(ready.config_digest, configuration.config_digest, DIGEST_SIZE);
  if (write_record_new(directory.directory_fd, ready_name, &ready) != 0) {
    if (errno != EEXIST || validate_existing_record(directory.directory_fd, ready_name, RECORD_READY_ACK,
                                                     &ready) != 0) {
      (void)fail_errno("cannot write sidecar ready acknowledgement");
      goto cleanup;
    }
  }
  active.current = current;
  active.waiting = waiting;
  memcpy(active.generation_hex, generation_hex, sizeof(generation_hex));
  memcpy(active.run_hex, run_hex, sizeof(run_hex));
  for (;;) {
    if (load_decision_record(directory.directory_fd, &active, &configuration, &decision) == 0) {
      break;
    }
    if (errno != ENOENT || sleep_briefly() != 0) {
      (void)fail_errno("cannot wait for sidecar decision");
      goto cleanup;
    }
  }
  if (record_digest(&decision, decision_digest) != 0) {
    (void)fail_errno("cannot hash sidecar decision");
    goto cleanup;
  }
  if (decision.flags == DECISION_ABORT) {
    memset(&acknowledgement, 0, sizeof(acknowledgement));
    acknowledgement.type = RECORD_ABORT_ACK;
    memcpy(acknowledgement.generation, generation, DIGEST_SIZE);
    memcpy(acknowledgement.run_nonce, run_nonce, DIGEST_SIZE);
    memcpy(acknowledgement.config_digest, configuration.config_digest, DIGEST_SIZE);
    memcpy(acknowledgement.binding_digest, decision_digest, DIGEST_SIZE);
    if (make_state_name(acknowledgement_name, sizeof(acknowledgement_name), "abort-ack", generation_hex,
                        run_hex) != 0 ||
        (write_record_new(directory.directory_fd, acknowledgement_name, &acknowledgement) != 0 &&
         (errno != EEXIST || validate_existing_record(directory.directory_fd, acknowledgement_name,
                                                       RECORD_ABORT_ACK, &acknowledgement) != 0))) {
      (void)fail_errno("cannot write sidecar abort acknowledgement");
      goto cleanup;
    }
    result = 0;
    goto cleanup;
  }
  if (read_record_at(directory.directory_fd, current_name, RECORD_CURRENT, &verified_current) != 0 ||
      verified_current.flags != 1U ||
      !constant_time_equal(verified_current.generation, generation, DIGEST_SIZE) ||
      !constant_time_equal(verified_current.run_nonce, run_nonce, DIGEST_SIZE) ||
      !constant_time_equal(verified_current.config_digest, configuration.config_digest, DIGEST_SIZE)) {
    errno = EPROTO;
    (void)fail_errno("cannot execute unverified sidecar commit");
    goto cleanup;
  }
  if (verify_mount_identity(&configuration, "/var/lib/postgresql") != 0) {
    (void)fail_errno("cannot execute sidecar commit with mismatched mount identity");
    goto cleanup;
  }
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
  if (wait_for_test_hook(cli, "test commit-decision barrier") != 0) {
    goto cleanup;
  }
#endif
  execution_mode = strchr((const char *)configuration.argv.items[0].bytes, '/') != NULL
                       ? EXECUTION_SLASH
                       : EXECUTION_PATH;
  if (exec_detail_digest(&configuration, execution_mode, execution_detail) != 0) {
    (void)fail_errno("invalid sidecar execution path");
    goto cleanup;
  }
  memset(&acknowledgement, 0, sizeof(acknowledgement));
  acknowledgement.type = RECORD_COMMIT_ACK;
  acknowledgement.flags = (uint32_t)execution_mode;
  memcpy(acknowledgement.generation, generation, DIGEST_SIZE);
  memcpy(acknowledgement.run_nonce, run_nonce, DIGEST_SIZE);
  memcpy(acknowledgement.config_digest, configuration.config_digest, DIGEST_SIZE);
  memcpy(acknowledgement.binding_digest, decision_digest, DIGEST_SIZE);
  memcpy(acknowledgement.detail_digest, execution_detail, DIGEST_SIZE);
  if (write_record_new(directory.directory_fd, acknowledgement_name, &acknowledgement) != 0 &&
      (errno != EEXIST || validate_existing_record(directory.directory_fd, acknowledgement_name,
                                                    RECORD_COMMIT_ACK, &acknowledgement) != 0)) {
    (void)fail_errno("cannot write sidecar commit acknowledgement");
    goto cleanup;
  }
  if (exec_original(&configuration) != 0) {
    (void)fail_errno("cannot execute sidecar entrypoint");
  }

cleanup:
  if (waiting_liveness_fd >= 0) {
    (void)close(waiting_liveness_fd);
  }
  configuration_free(&configuration);
  close_state_directory(&directory);
  return result;
}

static int set_option_once(const char **target, const char *value) {
  if (*target != NULL) {
    return -1;
  }
  *target = value;
  return 0;
}

static int parse_cli(int argc, char **argv, struct parsed_cli *cli) {
  int index;

  memset(cli, 0, sizeof(*cli));
  cli->config_fd = -1;
  cli->state_archive_fd = -1;
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
  cli->test_ready_fd = -1;
  cli->test_release_fd = -1;
#endif
  if (argc < 2) {
    return -1;
  }
  cli->mode = argv[1];
  if (strcmp(cli->mode, "encode") != 0 && strcmp(cli->mode, "archive") != 0 &&
      strcmp(cli->mode, "run") != 0 && strcmp(cli->mode, "verify") != 0 &&
      strcmp(cli->mode, "release") != 0 && strcmp(cli->mode, "decision") != 0 &&
      strcmp(cli->mode, "ack") != 0) {
    return -1;
  }
  for (index = 2; index < argc; ++index) {
    const char *option = argv[index];
    const char *value = NULL;

    if (strcmp(option, "--prepare") == 0) {
      if (cli->prepare) return -1;
      cli->prepare = true;
      continue;
    }
    if (strcmp(option, "--query") == 0) {
      if (cli->query) return -1;
      cli->query = true;
      continue;
    }
    if (strcmp(option, "--commit") == 0 || strcmp(option, "--abort") == 0) {
      if (cli->decision != 0) return -1;
      cli->decision = strcmp(option, "--commit") == 0 ? DECISION_COMMIT : DECISION_ABORT;
      continue;
    }
    if (strcmp(option, "--wait") == 0) {
      if (cli->wait) return -1;
      cli->wait = true;
      continue;
    }
    if (index + 1 >= argc) {
      return -1;
    }
    value = argv[++index];
    if (strcmp(option, "--config") == 0) {
      if (set_option_once(&cli->config_path, value) != 0) return -1;
    } else if (strcmp(option, "--mount") == 0) {
      if (set_option_once(&cli->mount_path, value) != 0) return -1;
    } else if (strcmp(option, "--generation") == 0) {
      if (set_option_once(&cli->generation_text, value) != 0) return -1;
    } else if (strcmp(option, "--expected-dev") == 0) {
      if (set_option_once(&cli->expected_dev_text, value) != 0) return -1;
    } else if (strcmp(option, "--expected-ino") == 0) {
      if (set_option_once(&cli->expected_ino_text, value) != 0) return -1;
    } else if (strcmp(option, "--entrypoint-json") == 0) {
      if (set_option_once(&cli->entrypoint_json, value) != 0) return -1;
    } else if (strcmp(option, "--cmd-json") == 0) {
      if (set_option_once(&cli->cmd_json, value) != 0) return -1;
    } else if (strcmp(option, "--environment-json") == 0) {
      if (set_option_once(&cli->environment_json, value) != 0) return -1;
    } else if (strcmp(option, "--decision") == 0) {
      if (cli->decision != 0 || cli->decision_option ||
          (strcmp(value, "commit") != 0 && strcmp(value, "abort") != 0)) return -1;
      cli->decision = strcmp(value, "commit") == 0 ? DECISION_COMMIT : DECISION_ABORT;
      cli->decision_option = true;
    } else if (strcmp(option, "--config-fd") == 0) {
      if (cli->has_config_fd || parse_fd(value, &cli->config_fd) != 0) return -1;
      cli->has_config_fd = true;
    } else if (strcmp(option, "--state-archive-fd") == 0) {
      if (cli->has_state_archive_fd || parse_fd(value, &cli->state_archive_fd) != 0) return -1;
      cli->has_state_archive_fd = true;
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
    } else if (strcmp(option, "--test-after-commit-decision-before-ack-ready-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 1) || cli->test_ready_fd >= 0 ||
          parse_fd(value, &cli->test_ready_fd) != 0) return -1;
      cli->test_hook_kind = 1;
    } else if (strcmp(option, "--test-after-commit-decision-before-ack-release-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 1) || cli->test_release_fd >= 0 ||
          parse_fd(value, &cli->test_release_fd) != 0) return -1;
      cli->test_hook_kind = 1;
    } else if (strcmp(option, "--test-after-commit-ack-before-return-ready-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 2) || cli->test_ready_fd >= 0 ||
          parse_fd(value, &cli->test_ready_fd) != 0) return -1;
      cli->test_hook_kind = 2;
    } else if (strcmp(option, "--test-after-commit-ack-before-return-release-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 2) || cli->test_release_fd >= 0 ||
          parse_fd(value, &cli->test_release_fd) != 0) return -1;
      cli->test_hook_kind = 2;
    } else if (strcmp(option, "--test-after-decision-file-fsync-before-directory-fsync-ready-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 3) || cli->test_ready_fd >= 0 ||
          parse_fd(value, &cli->test_ready_fd) != 0) return -1;
      cli->test_hook_kind = 3;
    } else if (strcmp(option, "--test-after-decision-file-fsync-before-directory-fsync-release-fd") == 0) {
      if ((cli->test_hook_kind != 0 && cli->test_hook_kind != 3) || cli->test_release_fd >= 0 ||
          parse_fd(value, &cli->test_release_fd) != 0) return -1;
      cli->test_hook_kind = 3;
#endif
    } else {
      return -1;
    }
  }
  if (strcmp(cli->mode, "archive") != 0 && cli->generation_text == NULL) {
    return -1;
  }
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
  if ((cli->test_ready_fd < 0) != (cli->test_release_fd < 0) ||
      (cli->test_hook_kind != 0 && strcmp(cli->mode, "run") != 0 && strcmp(cli->mode, "ack") != 0 &&
       strcmp(cli->mode, "decision") != 0)) {
    return -1;
  }
#endif
  if (strcmp(cli->mode, "encode") == 0) {
    return cli->has_config_fd && cli->expected_dev_text != NULL && cli->expected_ino_text != NULL &&
                   cli->entrypoint_json != NULL && cli->cmd_json != NULL && cli->environment_json != NULL &&
                   !cli->has_state_archive_fd && cli->config_path == NULL && cli->mount_path == NULL &&
                   !cli->prepare && !cli->query && cli->decision == 0 && !cli->wait
               ? 0
               : -1;
  }
  if (strcmp(cli->mode, "archive") == 0) {
    return cli->has_config_fd && !cli->has_state_archive_fd && cli->config_path == NULL &&
                   cli->mount_path == NULL && cli->expected_dev_text == NULL && cli->expected_ino_text == NULL &&
                   cli->entrypoint_json == NULL && cli->cmd_json == NULL && cli->environment_json == NULL &&
                   !cli->prepare && !cli->query && cli->decision == 0 && !cli->wait
               ? 0
               : -1;
  }
  if (strcmp(cli->mode, "run") == 0) {
    if (cli->config_path == NULL || cli->has_config_fd || cli->has_state_archive_fd || cli->mount_path != NULL ||
        cli->expected_dev_text != NULL || cli->expected_ino_text != NULL || cli->entrypoint_json != NULL ||
        cli->cmd_json != NULL || cli->environment_json != NULL || cli->prepare || cli->query || cli->decision != 0 ||
        cli->wait) return -1;
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
    return cli->test_hook_kind == 0 || cli->test_hook_kind == 1 ? 0 : -1;
#else
    return 0;
#endif
  }
  if (strcmp(cli->mode, "verify") == 0) {
    return cli->config_path != NULL && cli->mount_path != NULL && !cli->has_config_fd &&
                   !cli->has_state_archive_fd && !cli->prepare && !cli->query && cli->decision == 0 && !cli->wait
               ? 0
               : -1;
  }
  if (strcmp(cli->mode, "release") == 0) {
    return cli->config_path != NULL && cli->prepare && !cli->has_config_fd && !cli->has_state_archive_fd &&
                   cli->mount_path == NULL && !cli->query && cli->decision == 0 && !cli->wait
               ? 0
               : -1;
  }
  if (strcmp(cli->mode, "decision") == 0) {
    if (!((cli->config_path != NULL) != cli->has_state_archive_fd) || cli->decision_option ||
        !((cli->query && cli->decision == 0) || (!cli->query && cli->decision != 0)) || cli->has_config_fd ||
        cli->mount_path != NULL || cli->prepare || cli->wait) {
      return -1;
    }
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
    if (cli->test_hook_kind != 0 &&
        (cli->test_hook_kind != 3 || cli->config_path == NULL || cli->query || cli->decision == 0)) {
      return -1;
    }
#endif
    return 0;
  }
  if (strcmp(cli->mode, "ack") == 0) {
    const bool config_form = cli->config_path != NULL && !cli->has_state_archive_fd && cli->wait;
    const bool archive_form = cli->config_path == NULL && cli->has_state_archive_fd && cli->query && !cli->wait;

    if ((!config_form && !archive_form) || !cli->decision_option || cli->decision == 0 || cli->has_config_fd || cli->mount_path != NULL ||
        cli->prepare) return -1;
#ifdef OCSB_SIDECAR_GATE_TEST_HOOKS
    if (cli->test_hook_kind != 0 &&
        (!config_form || cli->decision != DECISION_COMMIT || cli->test_hook_kind != 2)) return -1;
#endif
    return 0;
  }
  return -1;
}

int main(int argc, char **argv) {
  struct parsed_cli cli;

  if (parse_cli(argc, argv, &cli) != 0) {
    errorf("invalid command line");
    return EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "encode") == 0) {
    return command_encode(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "archive") == 0) {
    return command_archive(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "run") == 0) {
    return command_run(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "verify") == 0) {
    return command_verify(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "release") == 0) {
    return command_release(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  if (strcmp(cli.mode, "decision") == 0) {
    return cli.has_state_archive_fd ? (command_decision_archive(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
                                    : (command_decision_config(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE);
  }
  return cli.has_state_archive_fd ? (command_ack_archive(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
                                  : (command_ack_config(&cli) == 0 ? EXIT_SUCCESS : EXIT_FAILURE);
}
