#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/capability.h>
#include <linux/btrfs.h>
#include <linux/mount.h>
#include <linux/openat2.h>
#include <sched.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#ifndef SYS_openat2
#ifdef __NR_openat2
#define SYS_openat2 __NR_openat2
#endif
#endif

#ifndef SYS_fsopen
#ifdef __NR_fsopen
#define SYS_fsopen __NR_fsopen
#endif
#endif
#ifndef SYS_fsconfig
#ifdef __NR_fsconfig
#define SYS_fsconfig __NR_fsconfig
#endif
#endif
#ifndef SYS_fsmount
#ifdef __NR_fsmount
#define SYS_fsmount __NR_fsmount
#endif
#endif
#ifndef SYS_move_mount
#ifdef __NR_move_mount
#define SYS_move_mount __NR_move_mount
#endif
#endif
#ifndef SYS_renameat2
#ifdef __NR_renameat2
#define SYS_renameat2 __NR_renameat2
#endif
#endif

enum backend_type {
  BACKEND_BUBBLEWRAP,
  BACKEND_PODMAN,
  BACKEND_NSPAWN,
};

enum namespace_type {
  NAMESPACE_BUBBLEWRAP_USER,
  NAMESPACE_CURRENT,
};

enum source_type {
  SOURCE_DIRECTORY,
  SOURCE_REGULAR,
};

enum inherited_root_role {
  INHERITED_ROOT_PROJECT,
  INHERITED_ROOT_STATE_BASE,
  INHERITED_ROOT_MOUNT,
};

enum source_requiredness {
  SOURCE_REQUIRED,
  SOURCE_OPTIONAL,
};

enum open_result {
  OPEN_RESULT_OK,
  OPEN_RESULT_ABSENT,
  OPEN_RESULT_UNSUPPORTED,
  OPEN_RESULT_ERROR,
};

enum workspace_action {
  WORKSPACE_ACTION_CREATE,
  WORKSPACE_ACTION_CONTINUE,
  WORKSPACE_ACTION_OVERWRITE,
};

enum workspace_strategy {
  WORKSPACE_STRATEGY_AUTO,
  WORKSPACE_STRATEGY_OVERLAYFS,
  WORKSPACE_STRATEGY_BTRFS,
  WORKSPACE_STRATEGY_GIT_WORKTREE,
  WORKSPACE_STRATEGY_DIRECT,
  WORKSPACE_STRATEGY_NONE,
};

struct workspace_mutation_spec {
  char *storage;
  const char *nonce;
  const char *project;
  dev_t project_dev;
  ino_t project_ino;
  const char *base;
  const char *workspace;
  enum workspace_action action;
  enum workspace_strategy requested_strategy;
  enum workspace_strategy cleanup_strategy;
  enum backend_type backend;
  const char *state_dir;
};

/*
 * Mutation-only CLI (it has no backend argv):
 *   --mutation-only --mutation-spec SPEC --workspace-receipt ABS_RECEIPT
 *   --git-bin /nix/store/.../bin/git
 *
 * SPEC has exactly twelve TAB-separated fields and no CR/LF:
 *   v1 nonce64 project project-dev project-ino base-rel workspace-name action
 *   requested-strategy cleanup-strategy backend state-dir
 *
 * Success is deliberately silent on stdout.  The caller reads ABS_RECEIPT only
 * through final mode's five all-or-nothing options: --workspace-receipt,
 * --workspace-nonce, --workspace-project, --workspace-base, and --workspace-name.
 */

/*
 * Workspace receipt schema (exactly 17 TAB-separated fields plus one final LF):
 *
 *   v1 nonce project-path base-rel workspace-name project-dev project-ino
 *   base-dev base-ino workspace-dev workspace-ino resolved-strategy backend
 *   child-name child-dev child-ino child-type
 *
 * child-name/dev/ino/type are "none"/0/0/"none" for direct and overlayfs,
 * "snapshot"/.../"btrfs-subvolume" for btrfs, and
 * "worktree"/.../"git-worktree" for git-worktree.  The path fields bind a
 * receipt to the immutable launcher inputs as well as to their inode identities.
 */
struct workspace_receipt_data {
  char *line;
  char *fields_storage;
  char *fields[17];
  int parent_fd;
  int receipt_fd;
  bool consume_attempted;
  struct stat file_stat;
  dev_t project_dev;
  ino_t project_ino;
  dev_t base_dev;
  ino_t base_ino;
  dev_t workspace_dev;
  ino_t workspace_ino;
  dev_t child_dev;
  ino_t child_ino;
  enum workspace_strategy strategy;
  enum backend_type backend;
};

struct workspace_tree {
  int project_fd;
  int base_fd;
  int workspace_fd;
  bool workspace_created;
  bool project_from_inherited_root;
};

struct source_spec {
  char *storage;
  char *token;
  char *absolute_path;
  char *containment_root;
  dev_t expected_dev;
  ino_t expected_ino;
  enum source_type expected_type;
  enum source_requiredness requiredness;
  size_t drop_start;
  size_t drop_count;
  size_t replacement_index;
  int source_fd;
  bool absent;
  bool consumed_by_overlay;
  char *anchor_path;
};

struct inherited_fd_spec {
  char *storage;
  enum inherited_root_role role;
  char *display_path;
  int file_descriptor;
  dev_t expected_dev;
  ino_t expected_ino;
  enum source_type expected_type;
};

struct replacement {
  char *storage;
  size_t index;
  char *token;
};

struct configuration {
  bool mutation_only;
  bool mutation_spec_set;
  bool workspace_receipt_set;
  bool workspace_nonce_set;
  bool workspace_project_set;
  bool workspace_base_set;
  bool workspace_name_set;
  bool git_bin_set;
  bool backend_set;
  bool namespace_set;
  bool host_uid_set;
  bool host_gid_set;
  bool anchor_root_set;
  enum backend_type backend;
  enum namespace_type namespace_mode;
  uid_t host_uid;
  gid_t host_gid;
  bool bubblewrap_rewrite_identity;
  uid_t bubblewrap_uid;
  gid_t bubblewrap_gid;
  char *anchor_root;
  struct workspace_mutation_spec mutation_spec;
  char *workspace_receipt_path;
  char *workspace_receipt_parent;
  char *workspace_receipt_name;
  char *workspace_nonce;
  char *workspace_project;
  char *workspace_base;
  char *workspace_name;
  char *git_bin;
  struct source_spec *sources;
  size_t source_count;
  size_t source_capacity;
  struct inherited_fd_spec *inherited_roots;
  size_t inherited_root_count;
  size_t inherited_root_capacity;
  struct replacement *replacements;
  size_t replacement_count;
  size_t replacement_capacity;
  char **backend_argv;
  size_t backend_argc;
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  int test_before_inherited_mutation_open_ready_fd;
  int test_before_inherited_mutation_open_release_fd;
  int test_before_inherited_final_open_ready_fd;
  int test_before_inherited_final_open_release_fd;
  int test_before_mutation_ready_fd;
  int test_before_mutation_release_fd;
  int test_before_receipt_open_ready_fd;
  int test_before_receipt_open_release_fd;
  int test_before_receipt_consume_ready_fd;
  int test_before_receipt_consume_release_fd;
  int test_after_moved_guard_validation_ready_fd;
  int test_after_moved_guard_validation_release_fd;
  int test_after_quarantined_receipt_validation_ready_fd;
  int test_after_quarantined_receipt_validation_release_fd;
#endif
};

static void errorf(const char *format, ...) {
  va_list arguments;

  fputs("ocsb: ", stderr);
  va_start(arguments, format);
  (void)vfprintf(stderr, format, arguments);
  va_end(arguments);
  fputc('\n', stderr);
}

static int fail_errno(const char *action, const char *path) {
  const int saved_errno = errno;

  if (path == NULL) {
    errorf("%s: %s", action, strerror(saved_errno));
  } else {
    errorf("%s: %s: %s", action, path, strerror(saved_errno));
  }
  return -1;
}

static int parse_uintmax_decimal(const char *text, uintmax_t *value_out) {
  uintmax_t value = 0;
  const unsigned char *cursor = (const unsigned char *)text;

  if (*cursor == '\0') {
    return -1;
  }
  for (; *cursor != '\0'; ++cursor) {
    const unsigned int digit = (unsigned int)(*cursor - (unsigned char)'0');

    if (*cursor < (unsigned char)'0' || *cursor > (unsigned char)'9' ||
        value > (UINTMAX_MAX - digit) / 10U) {
      return -1;
    }
    value = value * 10U + digit;
  }
  *value_out = value;
  return 0;
}

static int parse_size_decimal(const char *text, size_t *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || (uintmax_t)(size_t)value != value) {
    return -1;
  }
  *value_out = (size_t)value;
  return 0;
}

static int parse_uid(const char *text, uid_t *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || (uintmax_t)(uid_t)value != value) {
    return -1;
  }
  *value_out = (uid_t)value;
  return 0;
}

static int parse_gid(const char *text, gid_t *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || (uintmax_t)(gid_t)value != value) {
    return -1;
  }
  *value_out = (gid_t)value;
  return 0;
}

#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
static int parse_test_hook_fd(const char *text, int *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || value > (uintmax_t)INT_MAX) {
    return -1;
  }
  *value_out = (int)value;
  return 0;
}
#endif

static int parse_dev(const char *text, dev_t *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || (uintmax_t)(dev_t)value != value) {
    return -1;
  }
  *value_out = (dev_t)value;
  return 0;
}

static int parse_ino(const char *text, ino_t *value_out) {
  uintmax_t value;

  if (parse_uintmax_decimal(text, &value) != 0 || (uintmax_t)(ino_t)value != value) {
    return -1;
  }
  *value_out = (ino_t)value;
  return 0;
}

static bool is_hex_nonce(const char *text) {
  size_t index;

  if (strlen(text) != 64U) {
    return false;
  }
  for (index = 0U; index < 64U; ++index) {
    const unsigned char character = (unsigned char)text[index];

    if (!((character >= (unsigned char)'0' && character <= (unsigned char)'9') ||
          (character >= (unsigned char)'a' && character <= (unsigned char)'f') ||
          (character >= (unsigned char)'A' && character <= (unsigned char)'F'))) {
      return false;
    }
  }
  return true;
}

static bool is_safe_component(const char *text) {
  size_t index;

  if (text[0] == '\0' || strcmp(text, ".") == 0 || strcmp(text, "..") == 0 ||
      strlen(text) > NAME_MAX) {
    return false;
  }
  for (index = 0U; text[index] != '\0'; ++index) {
    const unsigned char character = (unsigned char)text[index];

    if (!((character >= (unsigned char)'a' && character <= (unsigned char)'z') ||
          (character >= (unsigned char)'A' && character <= (unsigned char)'Z') ||
          (character >= (unsigned char)'0' && character <= (unsigned char)'9') ||
          character == (unsigned char)'.' || character == (unsigned char)'_' ||
          character == (unsigned char)'-')) {
      return false;
    }
  }
  return true;
}

static int validate_absolute_path(const char *text) {
  const size_t length = strlen(text);
  size_t cursor;

  if (text[0] != '/' || length >= PATH_MAX || strchr(text, '\t') != NULL ||
      strchr(text, '\n') != NULL || strchr(text, '\r') != NULL) {
    return -1;
  }
  if (length == 1U) {
    return 0;
  }
  if (text[length - 1U] == '/') {
    return -1;
  }
  cursor = 1U;
  while (cursor < length) {
    const size_t component_start = cursor;
    size_t component_length;

    while (cursor < length && text[cursor] != '/') {
      ++cursor;
    }
    component_length = cursor - component_start;
    if (component_length == 0U || component_length > NAME_MAX ||
        (component_length == 1U && text[component_start] == '.') ||
        (component_length == 2U && text[component_start] == '.' &&
         text[component_start + 1U] == '.')) {
      return -1;
    }
    if (cursor < length) {
      ++cursor;
      if (cursor == length || text[cursor] == '/') {
        return -1;
      }
    }
  }
  return 0;
}

static int validate_base_relative_path(const char *text) {
  const size_t length = strlen(text);
  size_t cursor = 0U;

  if (text[0] == '\0' || text[0] == '/' || text[length - 1U] == '/' || length >= PATH_MAX ||
      strchr(text, '\t') != NULL || strchr(text, '\n') != NULL || strchr(text, '\r') != NULL) {
    return -1;
  }
  while (cursor < length) {
    const size_t component_start = cursor;
    size_t component_length;
    char component[NAME_MAX + 1U];

    while (cursor < length && text[cursor] != '/') {
      ++cursor;
    }
    component_length = cursor - component_start;
    if (component_length == 0U || component_length > NAME_MAX) {
      return -1;
    }
    memcpy(component, text + component_start, component_length);
    component[component_length] = '\0';
    if (!is_safe_component(component)) {
      return -1;
    }
    if (cursor < length) {
      ++cursor;
    }
  }
  return 0;
}

static const char *workspace_strategy_name(enum workspace_strategy strategy) {
  switch (strategy) {
    case WORKSPACE_STRATEGY_AUTO:
      return "auto";
    case WORKSPACE_STRATEGY_OVERLAYFS:
      return "overlayfs";
    case WORKSPACE_STRATEGY_BTRFS:
      return "btrfs";
    case WORKSPACE_STRATEGY_GIT_WORKTREE:
      return "git-worktree";
    case WORKSPACE_STRATEGY_DIRECT:
      return "direct";
    case WORKSPACE_STRATEGY_NONE:
      return "none";
  }
  return NULL;
}

static const char *workspace_backend_name(enum backend_type backend) {
  switch (backend) {
    case BACKEND_BUBBLEWRAP:
      return "bubblewrap";
    case BACKEND_PODMAN:
      return "podman";
    case BACKEND_NSPAWN:
      return "systemd-nspawn";
  }
  return NULL;
}

static int parse_workspace_strategy(const char *text, bool allow_auto, bool allow_none,
                                    enum workspace_strategy *strategy_out) {
  if (allow_auto && strcmp(text, "auto") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_AUTO;
  } else if (strcmp(text, "overlayfs") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_OVERLAYFS;
  } else if (strcmp(text, "btrfs") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_BTRFS;
  } else if (strcmp(text, "git-worktree") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_GIT_WORKTREE;
  } else if (strcmp(text, "direct") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_DIRECT;
  } else if (allow_none && strcmp(text, "none") == 0) {
    *strategy_out = WORKSPACE_STRATEGY_NONE;
  } else {
    return -1;
  }
  return 0;
}

static int parse_workspace_backend(const char *text, enum backend_type *backend_out) {
  if (strcmp(text, "bubblewrap") == 0) {
    *backend_out = BACKEND_BUBBLEWRAP;
  } else if (strcmp(text, "podman") == 0) {
    *backend_out = BACKEND_PODMAN;
  } else if (strcmp(text, "systemd-nspawn") == 0) {
    *backend_out = BACKEND_NSPAWN;
  } else {
    return -1;
  }
  return 0;
}

static int parse_workspace_action(const char *text, enum workspace_action *action_out) {
  if (strcmp(text, "create") == 0) {
    *action_out = WORKSPACE_ACTION_CREATE;
  } else if (strcmp(text, "continue") == 0) {
    *action_out = WORKSPACE_ACTION_CONTINUE;
  } else if (strcmp(text, "overwrite") == 0) {
    *action_out = WORKSPACE_ACTION_OVERWRITE;
  } else {
    return -1;
  }
  return 0;
}

static int parse_mutation_spec(struct configuration *configuration, const char *argument) {
  char *storage = NULL;
  char *fields[12];
  char *cursor;
  size_t index;
  struct workspace_mutation_spec parsed = { 0 };

  if (strchr(argument, '\n') != NULL || strchr(argument, '\r') != NULL) {
    errorf("invalid --mutation-spec: expected one TAB-separated line");
    return -1;
  }
  storage = strdup(argument);
  if (storage == NULL) {
    errorf("cannot allocate --mutation-spec");
    return -1;
  }
  cursor = storage;
  for (index = 0U; index < 11U; ++index) {
    char *tab = strchr(cursor, '\t');

    if (tab == NULL) {
      errorf("invalid --mutation-spec: expected twelve TAB-separated fields");
      free(storage);
      return -1;
    }
    *tab = '\0';
    fields[index] = cursor;
    cursor = tab + 1;
  }
  if (strchr(cursor, '\t') != NULL) {
    errorf("invalid --mutation-spec: expected twelve TAB-separated fields");
    free(storage);
    return -1;
  }
  fields[11] = cursor;
  if (strcmp(fields[0], "v1") != 0 || !is_hex_nonce(fields[1]) ||
      validate_absolute_path(fields[2]) != 0 || parse_dev(fields[3], &parsed.project_dev) != 0 ||
      parse_ino(fields[4], &parsed.project_ino) != 0 || validate_base_relative_path(fields[5]) != 0 ||
      !is_safe_component(fields[6]) || parse_workspace_action(fields[7], &parsed.action) != 0 ||
      parse_workspace_strategy(fields[8], true, false, &parsed.requested_strategy) != 0 ||
      parse_workspace_strategy(fields[9], false, true, &parsed.cleanup_strategy) != 0 ||
      parse_workspace_backend(fields[10], &parsed.backend) != 0 ||
      validate_absolute_path(fields[11]) != 0) {
    errorf("invalid --mutation-spec");
    free(storage);
    return -1;
  }
  if (parsed.project_dev == 0 || parsed.project_ino == 0) {
    errorf("invalid --mutation-spec project identity");
    free(storage);
    return -1;
  }
  parsed.storage = storage;
  parsed.nonce = fields[1];
  parsed.project = fields[2];
  parsed.base = fields[5];
  parsed.workspace = fields[6];
  parsed.state_dir = fields[11];
  configuration->mutation_spec = parsed;
  configuration->mutation_spec_set = true;
  return 0;
}

static int set_workspace_receipt_path(struct configuration *configuration, const char *argument) {
  const char *slash;
  size_t parent_length;
  char *path = NULL;
  char *parent = NULL;
  char *name = NULL;

  if (validate_absolute_path(argument) != 0) {
    errorf("--workspace-receipt must be a canonical absolute path");
    return -1;
  }
  slash = strrchr(argument, '/');
  if (slash == NULL || slash[1] == '\0' || !is_safe_component(slash + 1)) {
    errorf("--workspace-receipt must have a safe file name");
    return -1;
  }
  parent_length = slash == argument ? 1U : (size_t)(slash - argument);
  path = strdup(argument);
  parent = malloc(parent_length + 1U);
  name = strdup(slash + 1);
  if (path == NULL || parent == NULL || name == NULL) {
    free(path);
    free(parent);
    free(name);
    errorf("cannot allocate --workspace-receipt");
    return -1;
  }
  memcpy(parent, argument, parent_length);
  parent[parent_length] = '\0';
  configuration->workspace_receipt_path = path;
  configuration->workspace_receipt_parent = parent;
  configuration->workspace_receipt_name = name;
  configuration->workspace_receipt_set = true;
  return 0;
}

static int set_workspace_string(char **destination, bool *is_set, const char *argument,
                                const char *option, int (*validator)(const char *)) {
  char *copy;

  if (*is_set || validator(argument) != 0) {
    errorf("invalid or duplicate %s", option);
    return -1;
  }
  copy = strdup(argument);
  if (copy == NULL) {
    errorf("cannot allocate %s", option);
    return -1;
  }
  *destination = copy;
  *is_set = true;
  return 0;
}

static int validate_nonce_argument(const char *text) {
  return is_hex_nonce(text) ? 0 : -1;
}

static int validate_workspace_component_argument(const char *text) {
  return is_safe_component(text) ? 0 : -1;
}

static int validate_git_binary(const char *text) {
  /* The launcher supplies ${pkgs.git}/bin/git; this check keeps the helper
   * independent of a particular Nix store hash while rejecting indirections. */
  return validate_absolute_path(text) == 0 && strstr(text, "/proc/self/fd") == NULL &&
                 access(text, X_OK) == 0
             ? 0
             : -1;
}

static int push_source(struct configuration *configuration, struct source_spec source) {
  struct source_spec *expanded;
  size_t next_capacity;

  if (configuration->source_count == configuration->source_capacity) {
    next_capacity = configuration->source_capacity == 0U ? 8U : configuration->source_capacity * 2U;
    if (next_capacity < configuration->source_capacity ||
        next_capacity > SIZE_MAX / sizeof(*configuration->sources)) {
      errorf("too many source specifications");
      return -1;
    }
    expanded = realloc(configuration->sources, next_capacity * sizeof(*configuration->sources));
    if (expanded == NULL) {
      errorf("cannot allocate source specifications");
      return -1;
    }
    configuration->sources = expanded;
    configuration->source_capacity = next_capacity;
  }
  configuration->sources[configuration->source_count++] = source;
  return 0;
}

static int parse_inherited_root_role(const char *text, enum inherited_root_role *role_out) {
  if (strcmp(text, "project") == 0) {
    *role_out = INHERITED_ROOT_PROJECT;
  } else if (strcmp(text, "state-base") == 0) {
    *role_out = INHERITED_ROOT_STATE_BASE;
  } else if (strcmp(text, "mount") == 0) {
    *role_out = INHERITED_ROOT_MOUNT;
  } else {
    return -1;
  }
  return 0;
}

static int push_inherited_root(struct configuration *configuration, struct inherited_fd_spec root) {
  struct inherited_fd_spec *expanded;
  size_t next_capacity;
  size_t index;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const struct inherited_fd_spec *existing = &configuration->inherited_roots[index];

    if (strcmp(existing->display_path, root.display_path) == 0) {
      if (existing->expected_type != root.expected_type) {
        errorf("conflicting inherited root types for display path: %s", root.display_path);
      } else {
        errorf("duplicate inherited root display path: %s", root.display_path);
      }
      return -1;
    }
    if (root.role != INHERITED_ROOT_MOUNT && existing->role == root.role) {
      errorf("duplicate inherited root role");
      return -1;
    }
  }
  if (configuration->inherited_root_count == configuration->inherited_root_capacity) {
    next_capacity = configuration->inherited_root_capacity == 0U
                        ? 8U
                        : configuration->inherited_root_capacity * 2U;
    if (next_capacity < configuration->inherited_root_capacity ||
        next_capacity > SIZE_MAX / sizeof(*configuration->inherited_roots)) {
      errorf("too many inherited descriptor specifications");
      return -1;
    }
    expanded = realloc(configuration->inherited_roots,
                       next_capacity * sizeof(*configuration->inherited_roots));
    if (expanded == NULL) {
      errorf("cannot allocate inherited descriptor specifications");
      return -1;
    }
    configuration->inherited_roots = expanded;
    configuration->inherited_root_capacity = next_capacity;
  }
  configuration->inherited_roots[configuration->inherited_root_count++] = root;
  return 0;
}

static int parse_inherited_fd_spec(struct configuration *configuration, const char *argument) {
  char *storage = NULL;
  char *fields[7];
  char *cursor;
  size_t index;
  uintmax_t file_descriptor;
  struct inherited_fd_spec root = { 0 };

  if (strchr(argument, '\n') != NULL || strchr(argument, '\r') != NULL) {
    errorf("invalid --inherited-fd-spec: expected one TAB-separated line");
    return -1;
  }
  storage = strdup(argument);
  if (storage == NULL) {
    errorf("cannot allocate --inherited-fd-spec");
    return -1;
  }
  cursor = storage;
  for (index = 0U; index < 6U; ++index) {
    char *tab = strchr(cursor, '\t');

    if (tab == NULL) {
      errorf("invalid --inherited-fd-spec: expected seven TAB-separated fields");
      free(storage);
      return -1;
    }
    *tab = '\0';
    fields[index] = cursor;
    cursor = tab + 1;
  }
  if (strchr(cursor, '\t') != NULL) {
    errorf("invalid --inherited-fd-spec: expected seven TAB-separated fields");
    free(storage);
    return -1;
  }
  fields[6] = cursor;
  if (strcmp(fields[0], "v1") != 0 ||
      parse_inherited_root_role(fields[1], &root.role) != 0 ||
      validate_absolute_path(fields[2]) != 0 ||
      parse_uintmax_decimal(fields[3], &file_descriptor) != 0 || file_descriptor < 3U ||
      file_descriptor > (uintmax_t)INT_MAX || parse_dev(fields[4], &root.expected_dev) != 0 ||
      parse_ino(fields[5], &root.expected_ino) != 0) {
    errorf("invalid --inherited-fd-spec");
    free(storage);
    return -1;
  }
  if (strcmp(fields[6], "directory") == 0) {
    root.expected_type = SOURCE_DIRECTORY;
  } else if (strcmp(fields[6], "regular") == 0) {
    root.expected_type = SOURCE_REGULAR;
  } else {
    errorf("invalid --inherited-fd-spec type: %s", fields[6]);
    free(storage);
    return -1;
  }
  if ((root.role == INHERITED_ROOT_PROJECT || root.role == INHERITED_ROOT_STATE_BASE) &&
      root.expected_type != SOURCE_DIRECTORY) {
    errorf("invalid --inherited-fd-spec: project and state-base roots must be directories");
    free(storage);
    return -1;
  }
  root.storage = storage;
  root.display_path = fields[2];
  root.file_descriptor = (int)file_descriptor;
  if (push_inherited_root(configuration, root) != 0) {
    free(storage);
    return -1;
  }
  return 0;
}

static int validate_inherited_fd_specs(const struct configuration *configuration) {
  size_t index;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const struct inherited_fd_spec *root = &configuration->inherited_roots[index];
    struct stat status;

    if (fcntl(root->file_descriptor, F_GETFD) < 0) {
      return fail_errno("invalid --inherited-fd-spec descriptor", root->display_path);
    }
    if (fstat(root->file_descriptor, &status) != 0) {
      return fail_errno("invalid --inherited-fd-spec descriptor", root->display_path);
    }
    if (status.st_dev != root->expected_dev || status.st_ino != root->expected_ino ||
        (root->expected_type == SOURCE_DIRECTORY && !S_ISDIR(status.st_mode)) ||
        (root->expected_type == SOURCE_REGULAR && !S_ISREG(status.st_mode))) {
      errorf("invalid --inherited-fd-spec descriptor identity: %s", root->display_path);
      return -1;
    }
  }
  return 0;
}

static int push_replacement(struct configuration *configuration, struct replacement replacement) {
  struct replacement *expanded;
  size_t next_capacity;

  if (configuration->replacement_count == configuration->replacement_capacity) {
    next_capacity =
        configuration->replacement_capacity == 0U ? 8U : configuration->replacement_capacity * 2U;
    if (next_capacity < configuration->replacement_capacity ||
        next_capacity > SIZE_MAX / sizeof(*configuration->replacements)) {
      errorf("too many replacement specifications");
      return -1;
    }
    expanded = realloc(configuration->replacements,
                       next_capacity * sizeof(*configuration->replacements));
    if (expanded == NULL) {
      errorf("cannot allocate replacement specifications");
      return -1;
    }
    configuration->replacements = expanded;
    configuration->replacement_capacity = next_capacity;
  }
  configuration->replacements[configuration->replacement_count++] = replacement;
  return 0;
}

static int parse_source_spec(struct configuration *configuration, const char *argument) {
  char *storage = NULL;
  char *fields[9];
  char *cursor;
  struct source_spec source = { .replacement_index = SIZE_MAX, .source_fd = -1 };
  size_t index;

  storage = strdup(argument);
  if (storage == NULL) {
    errorf("cannot allocate source specification");
    return -1;
  }
  cursor = storage;
  for (index = 0U; index < 8U; ++index) {
    char *tab = strchr(cursor, '\t');

    if (tab == NULL) {
      errorf("invalid --source-spec: expected nine TAB-separated fields");
      free(storage);
      return -1;
    }
    *tab = '\0';
    fields[index] = cursor;
    cursor = tab + 1;
  }
  if (strchr(cursor, '\t') != NULL) {
    errorf("invalid --source-spec: expected nine TAB-separated fields");
    free(storage);
    return -1;
  }
  fields[8] = cursor;

  if (fields[0][0] == '\0' || fields[1][0] != '/' || fields[2][0] != '/' ||
      parse_dev(fields[3], &source.expected_dev) != 0 ||
      parse_ino(fields[4], &source.expected_ino) != 0 ||
      parse_size_decimal(fields[7], &source.drop_start) != 0 ||
      parse_size_decimal(fields[8], &source.drop_count) != 0) {
    errorf("invalid --source-spec");
    free(storage);
    return -1;
  }
  if (strcmp(fields[5], "directory") == 0) {
    source.expected_type = SOURCE_DIRECTORY;
  } else if (strcmp(fields[5], "regular") == 0) {
    source.expected_type = SOURCE_REGULAR;
  } else {
    errorf("invalid --source-spec type: %s", fields[5]);
    free(storage);
    return -1;
  }
  if (strcmp(fields[6], "required") == 0) {
    source.requiredness = SOURCE_REQUIRED;
  } else if (strcmp(fields[6], "optional") == 0) {
    source.requiredness = SOURCE_OPTIONAL;
  } else {
    errorf("invalid --source-spec requiredness: %s", fields[6]);
    free(storage);
    return -1;
  }

  source.storage = storage;
  source.token = fields[0];
  source.absolute_path = fields[1];
  source.containment_root = fields[2];
  if (push_source(configuration, source) != 0) {
    free(storage);
    return -1;
  }
  return 0;
}

static int parse_replacement(struct configuration *configuration, const char *argument) {
  char *storage = NULL;
  char *separator;
  struct replacement replacement;

  storage = strdup(argument);
  if (storage == NULL) {
    errorf("cannot allocate replacement specification");
    return -1;
  }
  separator = strchr(storage, ':');
  if (separator == NULL || separator == storage || separator[1] == '\0') {
    errorf("invalid --replace: %s", argument);
    free(storage);
    return -1;
  }
  *separator = '\0';
  if (parse_size_decimal(storage, &replacement.index) != 0) {
    errorf("invalid --replace index: %s", argument);
    free(storage);
    return -1;
  }
  replacement.storage = storage;
  replacement.token = separator + 1;
  if (push_replacement(configuration, replacement) != 0) {
    free(storage);
    return -1;
  }
  return 0;
}

static int set_anchor_root(struct configuration *configuration, const char *argument) {
  char *copy;
  size_t length;

  if (argument[0] != '/') {
    errorf("--anchor-root must be an absolute path");
    return -1;
  }
  copy = strdup(argument);
  if (copy == NULL) {
    errorf("cannot allocate --anchor-root");
    return -1;
  }
  length = strlen(copy);
  while (length > 1U && copy[length - 1U] == '/') {
    copy[--length] = '\0';
  }
  configuration->anchor_root = copy;
  configuration->anchor_root_set = true;
  return 0;
}

static int parse_backend(struct configuration *configuration, const char *argument) {
  if (strcmp(argument, "bubblewrap") == 0) {
    configuration->backend = BACKEND_BUBBLEWRAP;
  } else if (strcmp(argument, "podman") == 0) {
    configuration->backend = BACKEND_PODMAN;
  } else if (strcmp(argument, "systemd-nspawn") == 0 || strcmp(argument, "nspawn") == 0) {
    configuration->backend = BACKEND_NSPAWN;
  } else {
    errorf("unsupported backend: %s", argument);
    return -1;
  }
  configuration->backend_set = true;
  return 0;
}

static int parse_namespace(struct configuration *configuration, const char *argument) {
  if (strcmp(argument, "bubblewrap-user") == 0) {
    configuration->namespace_mode = NAMESPACE_BUBBLEWRAP_USER;
  } else if (strcmp(argument, "current") == 0) {
    configuration->namespace_mode = NAMESPACE_CURRENT;
  } else {
    errorf("unsupported mount-anchor namespace: %s", argument);
    return -1;
  }
  configuration->namespace_set = true;
  return 0;
}

static bool option_takes_value(const char *option) {
  return strcmp(option, "--backend") == 0 || strcmp(option, "--namespace") == 0 ||
          strcmp(option, "--host-uid") == 0 || strcmp(option, "--host-gid") == 0 ||
          strcmp(option, "--anchor-root") == 0 || strcmp(option, "--source-spec") == 0 ||
          strcmp(option, "--replace") == 0 || strcmp(option, "--inherited-fd-spec") == 0 ||
          strcmp(option, "--mutation-spec") == 0 ||
          strcmp(option, "--workspace-receipt") == 0 || strcmp(option, "--workspace-nonce") == 0 ||
         strcmp(option, "--workspace-project") == 0 || strcmp(option, "--workspace-base") == 0 ||
         strcmp(option, "--workspace-name") == 0 || strcmp(option, "--git-bin") == 0
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
           || strcmp(option, "--test-before-inherited-mutation-open-ready-fd") == 0 ||
           strcmp(option, "--test-before-inherited-mutation-open-release-fd") == 0 ||
           strcmp(option, "--test-before-inherited-final-open-ready-fd") == 0 ||
           strcmp(option, "--test-before-inherited-final-open-release-fd") == 0 ||
           strcmp(option, "--test-before-mutation-ready-fd") == 0 ||
          strcmp(option, "--test-before-mutation-release-fd") == 0 ||
          strcmp(option, "--test-before-receipt-open-ready-fd") == 0 ||
          strcmp(option, "--test-before-receipt-open-release-fd") == 0 ||
          strcmp(option, "--test-before-receipt-consume-ready-fd") == 0 ||
          strcmp(option, "--test-before-receipt-consume-release-fd") == 0 ||
          strcmp(option, "--test-after-moved-guard-validation-ready-fd") == 0 ||
          strcmp(option, "--test-after-moved-guard-validation-release-fd") == 0 ||
          strcmp(option, "--test-after-quarantined-receipt-validation-ready-fd") == 0 ||
          strcmp(option, "--test-after-quarantined-receipt-validation-release-fd") == 0
#endif
      ;
}

static int parse_cli(int argc, char **argv, struct configuration *configuration) {
  int index;

  for (index = 1; index < argc; ++index) {
    const char *option = argv[index];
    const char *value;

    if (strcmp(option, "--") == 0) {
      if (configuration->mutation_only) {
        errorf("--mutation-only does not accept backend argv");
        return -1;
      }
      ++index;
      if (index >= argc) {
        errorf("missing backend argv after --");
        return -1;
      }
      configuration->backend_argv = &argv[index];
      configuration->backend_argc = (size_t)(argc - index);
      break;
    }
    if (strcmp(option, "--mutation-only") == 0) {
      if (configuration->mutation_only) {
        errorf("--mutation-only specified more than once");
        return -1;
      }
      configuration->mutation_only = true;
      continue;
    }
    if (!option_takes_value(option)) {
      errorf("unknown option: %s", option);
      return -1;
    }
    if (index + 1 >= argc) {
      errorf("missing value for %s", option);
      return -1;
    }
    value = argv[++index];
    if (strcmp(option, "--backend") == 0) {
      if (configuration->backend_set || parse_backend(configuration, value) != 0) {
        if (configuration->backend_set) {
          errorf("--backend specified more than once");
        }
        return -1;
      }
    } else if (strcmp(option, "--namespace") == 0) {
      if (configuration->namespace_set || parse_namespace(configuration, value) != 0) {
        if (configuration->namespace_set) {
          errorf("--namespace specified more than once");
        }
        return -1;
      }
    } else if (strcmp(option, "--host-uid") == 0) {
      if (configuration->host_uid_set || parse_uid(value, &configuration->host_uid) != 0) {
        if (configuration->host_uid_set) {
          errorf("--host-uid specified more than once");
        } else {
          errorf("invalid --host-uid");
        }
        return -1;
      }
      configuration->host_uid_set = true;
    } else if (strcmp(option, "--host-gid") == 0) {
      if (configuration->host_gid_set || parse_gid(value, &configuration->host_gid) != 0) {
        if (configuration->host_gid_set) {
          errorf("--host-gid specified more than once");
        } else {
          errorf("invalid --host-gid");
        }
        return -1;
      }
      configuration->host_gid_set = true;
    } else if (strcmp(option, "--anchor-root") == 0) {
      if (configuration->anchor_root_set || set_anchor_root(configuration, value) != 0) {
        if (configuration->anchor_root_set) {
          errorf("--anchor-root specified more than once");
        }
        return -1;
      }
    } else if (strcmp(option, "--source-spec") == 0) {
      if (parse_source_spec(configuration, value) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--replace") == 0) {
      if (parse_replacement(configuration, value) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--inherited-fd-spec") == 0) {
      if (parse_inherited_fd_spec(configuration, value) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--mutation-spec") == 0) {
      if (configuration->mutation_spec_set || parse_mutation_spec(configuration, value) != 0) {
        if (configuration->mutation_spec_set) {
          errorf("--mutation-spec specified more than once");
        }
        return -1;
      }
    } else if (strcmp(option, "--workspace-receipt") == 0) {
      if (configuration->workspace_receipt_set || set_workspace_receipt_path(configuration, value) != 0) {
        if (configuration->workspace_receipt_set) {
          errorf("--workspace-receipt specified more than once");
        }
        return -1;
      }
    } else if (strcmp(option, "--workspace-nonce") == 0) {
      if (set_workspace_string(&configuration->workspace_nonce, &configuration->workspace_nonce_set,
                               value, "--workspace-nonce", validate_nonce_argument) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--workspace-project") == 0) {
      if (set_workspace_string(&configuration->workspace_project,
                               &configuration->workspace_project_set, value,
                               "--workspace-project", validate_absolute_path) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--workspace-base") == 0) {
      if (set_workspace_string(&configuration->workspace_base, &configuration->workspace_base_set,
                               value, "--workspace-base", validate_base_relative_path) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--workspace-name") == 0) {
      if (set_workspace_string(&configuration->workspace_name, &configuration->workspace_name_set,
                               value, "--workspace-name",
                               validate_workspace_component_argument) != 0) {
        return -1;
      }
    } else if (strcmp(option, "--git-bin") == 0) {
      if (set_workspace_string(&configuration->git_bin, &configuration->git_bin_set, value,
                               "--git-bin", validate_git_binary) != 0) {
        return -1;
      }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
    } else if (strcmp(option, "--test-before-inherited-mutation-open-ready-fd") == 0) {
      if (configuration->test_before_inherited_mutation_open_ready_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_inherited_mutation_open_ready_fd) !=
              0) {
        errorf("invalid or duplicate --test-before-inherited-mutation-open-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-inherited-mutation-open-release-fd") == 0) {
      if (configuration->test_before_inherited_mutation_open_release_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_inherited_mutation_open_release_fd) !=
              0) {
        errorf("invalid or duplicate --test-before-inherited-mutation-open-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-inherited-final-open-ready-fd") == 0) {
      if (configuration->test_before_inherited_final_open_ready_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_inherited_final_open_ready_fd) != 0) {
        errorf("invalid or duplicate --test-before-inherited-final-open-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-inherited-final-open-release-fd") == 0) {
      if (configuration->test_before_inherited_final_open_release_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_inherited_final_open_release_fd) != 0) {
        errorf("invalid or duplicate --test-before-inherited-final-open-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-mutation-ready-fd") == 0) {
      if (configuration->test_before_mutation_ready_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_mutation_ready_fd) != 0) {
        errorf("invalid or duplicate --test-before-mutation-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-mutation-release-fd") == 0) {
      if (configuration->test_before_mutation_release_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_mutation_release_fd) != 0) {
        errorf("invalid or duplicate --test-before-mutation-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-receipt-open-ready-fd") == 0) {
      if (configuration->test_before_receipt_open_ready_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_receipt_open_ready_fd) != 0) {
        errorf("invalid or duplicate --test-before-receipt-open-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-receipt-open-release-fd") == 0) {
      if (configuration->test_before_receipt_open_release_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_receipt_open_release_fd) != 0) {
        errorf("invalid or duplicate --test-before-receipt-open-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-receipt-consume-ready-fd") == 0) {
      if (configuration->test_before_receipt_consume_ready_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_receipt_consume_ready_fd) != 0) {
        errorf("invalid or duplicate --test-before-receipt-consume-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-before-receipt-consume-release-fd") == 0) {
      if (configuration->test_before_receipt_consume_release_fd >= 0 ||
          parse_test_hook_fd(value, &configuration->test_before_receipt_consume_release_fd) != 0) {
        errorf("invalid or duplicate --test-before-receipt-consume-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-after-moved-guard-validation-ready-fd") == 0) {
      if (configuration->test_after_moved_guard_validation_ready_fd >= 0 ||
          parse_test_hook_fd(value,
                             &configuration->test_after_moved_guard_validation_ready_fd) != 0) {
        errorf("invalid or duplicate --test-after-moved-guard-validation-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-after-moved-guard-validation-release-fd") == 0) {
      if (configuration->test_after_moved_guard_validation_release_fd >= 0 ||
          parse_test_hook_fd(value,
                             &configuration->test_after_moved_guard_validation_release_fd) != 0) {
        errorf("invalid or duplicate --test-after-moved-guard-validation-release-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-after-quarantined-receipt-validation-ready-fd") == 0) {
      if (configuration->test_after_quarantined_receipt_validation_ready_fd >= 0 ||
          parse_test_hook_fd(
              value, &configuration->test_after_quarantined_receipt_validation_ready_fd) != 0) {
        errorf("invalid or duplicate --test-after-quarantined-receipt-validation-ready-fd");
        return -1;
      }
    } else if (strcmp(option, "--test-after-quarantined-receipt-validation-release-fd") == 0) {
      if (configuration->test_after_quarantined_receipt_validation_release_fd >= 0 ||
          parse_test_hook_fd(
              value, &configuration->test_after_quarantined_receipt_validation_release_fd) != 0) {
        errorf("invalid or duplicate --test-after-quarantined-receipt-validation-release-fd");
        return -1;
      }
#endif
    }
  }

  if (configuration->mutation_only) {
    if (!configuration->mutation_spec_set || !configuration->workspace_receipt_set ||
        !configuration->git_bin_set || configuration->backend_set || configuration->namespace_set ||
        configuration->host_uid_set || configuration->host_gid_set || configuration->anchor_root_set ||
        configuration->source_count != 0U || configuration->replacement_count != 0U ||
        configuration->backend_argv != NULL || configuration->workspace_nonce_set ||
        configuration->workspace_project_set || configuration->workspace_base_set ||
        configuration->workspace_name_set) {
      errorf("invalid --mutation-only argument set");
      return -1;
    }
  } else {
    const unsigned int receipt_options = (unsigned int)configuration->workspace_receipt_set +
                                         (unsigned int)configuration->workspace_nonce_set +
                                         (unsigned int)configuration->workspace_project_set +
                                         (unsigned int)configuration->workspace_base_set +
                                         (unsigned int)configuration->workspace_name_set;

    if (configuration->mutation_spec_set || configuration->git_bin_set) {
      errorf("workspace mutation options require --mutation-only");
      return -1;
    }
    if (receipt_options != 0U && receipt_options != 5U) {
      errorf("workspace receipt options must be specified together");
      return -1;
    }
  }

  if (!configuration->mutation_only &&
      (!configuration->backend_set || !configuration->namespace_set || !configuration->host_uid_set ||
       !configuration->host_gid_set || !configuration->anchor_root_set ||
       configuration->backend_argv == NULL)) {
    errorf("missing required mount-anchor arguments");
    return -1;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
    if ((configuration->test_before_inherited_mutation_open_ready_fd >= 0) !=
            (configuration->test_before_inherited_mutation_open_release_fd >= 0) ||
        (configuration->test_before_inherited_final_open_ready_fd >= 0) !=
            (configuration->test_before_inherited_final_open_release_fd >= 0) ||
        (configuration->test_before_mutation_ready_fd >= 0) !=
            (configuration->test_before_mutation_release_fd >= 0) ||
        (configuration->test_before_receipt_open_ready_fd >= 0) !=
            (configuration->test_before_receipt_open_release_fd >= 0) ||
        (configuration->test_before_receipt_consume_ready_fd >= 0) !=
            (configuration->test_before_receipt_consume_release_fd >= 0) ||
        (configuration->test_after_moved_guard_validation_ready_fd >= 0) !=
            (configuration->test_after_moved_guard_validation_release_fd >= 0) ||
        (configuration->test_after_quarantined_receipt_validation_ready_fd >= 0) !=
            (configuration->test_after_quarantined_receipt_validation_release_fd >= 0)) {
    errorf("test hook ready and release FDs must be specified together");
    return -1;
  }
#endif
  return validate_inherited_fd_specs(configuration);
}

#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
static int close_test_hook_fd(int *file_descriptor) {
  if (*file_descriptor < 0) {
    return 0;
  }
  if (close(*file_descriptor) != 0) {
    *file_descriptor = -1;
    return -1;
  }
  *file_descriptor = -1;
  return 0;
}

static int close_test_hook_fds(struct configuration *configuration) {
  int result = 0;

  if (close_test_hook_fd(&configuration->test_before_inherited_mutation_open_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_inherited_mutation_open_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_inherited_final_open_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_inherited_final_open_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_mutation_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_mutation_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_receipt_open_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_receipt_open_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_receipt_consume_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_before_receipt_consume_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_after_moved_guard_validation_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(&configuration->test_after_moved_guard_validation_release_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(
          &configuration->test_after_quarantined_receipt_validation_ready_fd) != 0) {
    result = -1;
  }
  if (close_test_hook_fd(
          &configuration->test_after_quarantined_receipt_validation_release_fd) != 0) {
    result = -1;
  }
  return result;
}

static int wait_for_test_hook_pair(int *ready_fd, int *release_fd, const char *phase) {
  char ready_byte = 'R';
  char release_byte;
  ssize_t read_count;

  if (*ready_fd >= 0) {
    if (write(*ready_fd, &ready_byte, 1U) != 1) {
      if (errno == 0) {
        errno = EIO;
      }
      return fail_errno(phase, NULL);
    }
    do {
      read_count = read(*release_fd, &release_byte, 1U);
    } while (read_count < 0 && errno == EINTR);
    if (read_count != 1) {
      if (read_count == 0) {
        errno = EIO;
      }
      return fail_errno(phase, NULL);
    }
  }
  if (close_test_hook_fd(ready_fd) != 0 || close_test_hook_fd(release_fd) != 0) {
    return fail_errno("test hook: cannot close hook file descriptor", NULL);
  }
  return 0;
}

static int wait_for_test_mutation_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(&configuration->test_before_mutation_ready_fd,
                                 &configuration->test_before_mutation_release_fd,
                                 "test hook: cannot synchronize mutation barrier");
}

static int wait_for_test_inherited_mutation_open_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(&configuration->test_before_inherited_mutation_open_ready_fd,
                                 &configuration->test_before_inherited_mutation_open_release_fd,
                                 "test hook: cannot synchronize inherited-mutation-open barrier");
}

static int wait_for_test_inherited_final_open_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(&configuration->test_before_inherited_final_open_ready_fd,
                                 &configuration->test_before_inherited_final_open_release_fd,
                                 "test hook: cannot synchronize inherited-final-open barrier");
}

static int wait_for_test_receipt_open_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(&configuration->test_before_receipt_open_ready_fd,
                                 &configuration->test_before_receipt_open_release_fd,
                                 "test hook: cannot synchronize receipt-open barrier");
}

static int wait_for_test_receipt_consume_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(&configuration->test_before_receipt_consume_ready_fd,
                                 &configuration->test_before_receipt_consume_release_fd,
                                 "test hook: cannot synchronize receipt-consume barrier");
}

static int wait_for_test_moved_guard_validation_hook(struct configuration *configuration) {
  return wait_for_test_hook_pair(
      &configuration->test_after_moved_guard_validation_ready_fd,
      &configuration->test_after_moved_guard_validation_release_fd,
      "test hook: cannot synchronize moved-guard-validation barrier");
}

static int wait_for_test_quarantined_receipt_validation_hook(
    struct configuration *configuration) {
  return wait_for_test_hook_pair(
      &configuration->test_after_quarantined_receipt_validation_ready_fd,
      &configuration->test_after_quarantined_receipt_validation_release_fd,
      "test hook: cannot synchronize quarantined-receipt-validation barrier");
}
#endif

static size_t count_occurrences(const char *haystack, const char *needle) {
  const char *cursor = haystack;
  size_t count = 0U;
  const size_t needle_length = strlen(needle);

  if (needle_length == 0U) {
    return SIZE_MAX;
  }
  while ((cursor = strstr(cursor, needle)) != NULL) {
    if (count == SIZE_MAX) {
      return SIZE_MAX;
    }
    ++count;
    ++cursor;
  }
  return count;
}

static ssize_t source_index_for_token(const struct configuration *configuration, const char *token) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    if (strcmp(configuration->sources[index].token, token) == 0) {
      return (ssize_t)index;
    }
  }
  return -1;
}

static ssize_t source_index_for_replacement_index(const struct configuration *configuration,
                                                  size_t replacement_index) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    if (configuration->sources[index].replacement_index == replacement_index) {
      return (ssize_t)index;
    }
  }
  return -1;
}

static int podman_rootless_id_map_matches(const char *map_path, uintmax_t host_id) {
  FILE *map;
  uintmax_t inside_id;
  uintmax_t outside_id;
  uintmax_t length;

  map = fopen(map_path, "r");
  if (map == NULL) {
    return 0;
  }
  while (fscanf(map, "%" SCNuMAX " %" SCNuMAX " %" SCNuMAX, &inside_id, &outside_id,
                &length) == 3) {
    if (inside_id == 0U) {
      const int matches = outside_id == host_id && length == 1U;

      (void)fclose(map);
      return matches;
    }
  }
  (void)fclose(map);
  return 0;
}

static int write_proc_file(const char *path, const char *text);
static int bubblewrap_failure_errno(const char *stage);

static int id_map_covers_identity(const char *map_path, uintmax_t host_id) {
  FILE *map;
  uintmax_t inside_id;
  uintmax_t outside_id;
  uintmax_t length;

  map = fopen(map_path, "r");
  if (map == NULL) {
    return 0;
  }
  while (fscanf(map, "%" SCNuMAX " %" SCNuMAX " %" SCNuMAX, &inside_id, &outside_id,
                &length) == 3) {
    if (length != 0U && inside_id <= host_id && outside_id <= host_id &&
        host_id - inside_id == host_id - outside_id && host_id - inside_id < length) {
      (void)fclose(map);
      return 1;
    }
  }
  (void)fclose(map);
  return 0;
}

static int write_root_map_or_identity_fallback(const char *map_path, const char *root_map_text,
                                               const char *identity_map_text, uintmax_t host_id,
                                               const char *stage) {
  int saved_errno;

  if (write_proc_file(map_path, root_map_text) == 0) {
    return 0;
  }
  saved_errno = errno != 0 ? errno : EIO;
  if (write_proc_file(map_path, identity_map_text) == 0 ||
      id_map_covers_identity(map_path, host_id) ||
      podman_rootless_id_map_matches(map_path, host_id)) {
    return 0;
  }
  errno = saved_errno;
  return bubblewrap_failure_errno(stage);
}

static int validate_backend_namespace(const struct configuration *configuration) {
  const uid_t current_uid = getuid();
  const gid_t current_gid = getgid();

  if ((configuration->backend == BACKEND_BUBBLEWRAP &&
       configuration->namespace_mode != NAMESPACE_BUBBLEWRAP_USER) ||
      (configuration->backend != BACKEND_BUBBLEWRAP &&
       configuration->namespace_mode != NAMESPACE_CURRENT)) {
    errorf("invalid namespace for selected backend");
    return -1;
  }
  if (configuration->host_uid == current_uid && configuration->host_gid == current_gid) {
    return 0;
  }
  if (configuration->backend == BACKEND_PODMAN && current_uid == 0U && current_gid == 0U &&
      configuration->host_uid != 0U &&
      podman_rootless_id_map_matches("/proc/self/uid_map", (uintmax_t)configuration->host_uid) &&
      podman_rootless_id_map_matches("/proc/self/gid_map", (uintmax_t)configuration->host_gid)) {
    return 0;
  }
  if (configuration->backend == BACKEND_PODMAN) {
    errorf("identity changed: Podman current namespace does not map root to the captured host uid/gid");
  } else {
    errorf("identity changed: --host-uid and --host-gid must match the current process identity");
  }
  return -1;
}

static bool contains_proc_fd_path(const char *argument) {
  const char *candidate = argument;

  while ((candidate = strstr(candidate, "/proc/")) != NULL) {
    const char *component = candidate + strlen("/proc/");
    const char *digits = component;

    if (strncmp(component, "self/fd", strlen("self/fd")) == 0 &&
        (component[strlen("self/fd")] == '\0' || component[strlen("self/fd")] == '/')) {
      return true;
    }
    while (*digits >= '0' && *digits <= '9') {
      ++digits;
    }
    if (digits != component && strncmp(digits, "/fd/", strlen("/fd/")) == 0) {
      return true;
    }
    candidate = component;
  }
  return false;
}

static int validate_manifest(struct configuration *configuration) {
  size_t argv_index;
  size_t source_index;
  size_t replacement_index;

  if (configuration->backend_argv[0][0] != '/') {
    errorf("backend argv[0] must be an absolute path");
    return -1;
  }
  for (argv_index = 0U; argv_index < configuration->backend_argc; ++argv_index) {
    if (contains_proc_fd_path(configuration->backend_argv[argv_index])) {
      errorf("backend argv contains forbidden /proc/*/fd/ path");
      return -1;
    }
  }

  for (source_index = 0U; source_index < configuration->source_count; ++source_index) {
    struct source_spec *source = &configuration->sources[source_index];
    size_t other_source_index;

    for (other_source_index = 0U; other_source_index < source_index; ++other_source_index) {
      if (strcmp(source->token, configuration->sources[other_source_index].token) == 0) {
        errorf("duplicate source token: %s", source->token);
        return -1;
      }
    }
    if ((source->requiredness == SOURCE_REQUIRED &&
         (source->drop_start != 0U || source->drop_count != 0U)) ||
        (source->requiredness == SOURCE_OPTIONAL && source->drop_count == 0U)) {
      errorf("invalid optional drop range for source token: %s", source->token);
      return -1;
    }
    if (source->requiredness == SOURCE_OPTIONAL &&
        (source->drop_start == 0U || source->drop_start >= configuration->backend_argc ||
         source->drop_count > configuration->backend_argc - source->drop_start)) {
      errorf("optional drop range is outside backend argv: %s", source->token);
      return -1;
    }
  }

  for (replacement_index = 0U; replacement_index < configuration->replacement_count;
       ++replacement_index) {
    const struct replacement *replacement = &configuration->replacements[replacement_index];
    ssize_t found_source;
    size_t other_replacement_index;

    if (replacement->index >= configuration->backend_argc) {
      errorf("--replace index outside backend argv: %zu", replacement->index);
      return -1;
    }
    for (other_replacement_index = 0U; other_replacement_index < replacement_index;
         ++other_replacement_index) {
      const struct replacement *other = &configuration->replacements[other_replacement_index];

      if (other->index == replacement->index || strcmp(other->token, replacement->token) == 0) {
        errorf("duplicate --replace declaration: %s", replacement->token);
        return -1;
      }
    }
    found_source = source_index_for_token(configuration, replacement->token);
    if (found_source < 0) {
      errorf("--replace references an unknown source token: %s", replacement->token);
      return -1;
    }
    if (configuration->sources[found_source].replacement_index != SIZE_MAX) {
      errorf("duplicate --replace declaration: %s", replacement->token);
      return -1;
    }
    if (count_occurrences(configuration->backend_argv[replacement->index], replacement->token) != 1U) {
      errorf("--replace token must occur exactly once at backend argv index %zu", replacement->index);
      return -1;
    }
    configuration->sources[found_source].replacement_index = replacement->index;
  }

  for (source_index = 0U; source_index < configuration->source_count; ++source_index) {
    struct source_spec *source = &configuration->sources[source_index];
    size_t source_argv_index;
    size_t occurrences = 0U;

    if (source->replacement_index == SIZE_MAX) {
      errorf("unreferenced source token: %s", source->token);
      return -1;
    }
    for (source_argv_index = 0U; source_argv_index < configuration->backend_argc;
         ++source_argv_index) {
      const size_t count =
          count_occurrences(configuration->backend_argv[source_argv_index], source->token);

      if (count == SIZE_MAX || occurrences > SIZE_MAX - count) {
        errorf("source token occurrence count overflow: %s", source->token);
        return -1;
      }
      occurrences += count;
    }
    if (occurrences != 1U) {
      errorf("source token must occur exactly once in immutable backend argv: %s", source->token);
      return -1;
    }
    if (source->requiredness == SOURCE_OPTIONAL &&
        (source->replacement_index < source->drop_start ||
         source->replacement_index >= source->drop_start + source->drop_count)) {
      errorf("optional drop range does not contain its replacement: %s", source->token);
      return -1;
    }
  }

  for (source_index = 0U; source_index < configuration->source_count; ++source_index) {
    const struct source_spec *source = &configuration->sources[source_index];
    size_t other_source_index;

    if (source->requiredness != SOURCE_OPTIONAL) {
      continue;
    }
    for (other_source_index = 0U; other_source_index < source_index; ++other_source_index) {
      const struct source_spec *other = &configuration->sources[other_source_index];

      if (other->requiredness == SOURCE_OPTIONAL &&
          source->drop_start < other->drop_start + other->drop_count &&
          other->drop_start < source->drop_start + source->drop_count) {
        errorf("overlapping optional drop ranges");
        return -1;
      }
    }
    for (other_source_index = 0U; other_source_index < configuration->source_count;
         ++other_source_index) {
      const struct source_spec *other = &configuration->sources[other_source_index];

      if (other != source && other->replacement_index >= source->drop_start &&
          other->replacement_index < source->drop_start + source->drop_count) {
        errorf("optional drop range contains another source replacement: %s", source->token);
        return -1;
      }
    }
  }
  return 0;
}

static int directory_is_empty(int directory_fd) {
  DIR *directory;
  struct dirent *entry;
  int scan_fd = dup(directory_fd);

  if (scan_fd < 0) {
    return -1;
  }
  directory = fdopendir(scan_fd);
  if (directory == NULL) {
    const int saved_errno = errno;

    (void)close(scan_fd);
    errno = saved_errno;
    return -1;
  }
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
      (void)closedir(directory);
      errno = ENOTEMPTY;
      return -1;
    }
  }
  if (errno != 0) {
    const int saved_errno = errno;

    (void)closedir(directory);
    errno = saved_errno;
    return -1;
  }
  return closedir(directory);
}

static int prepare_anchor_root(const struct configuration *configuration, int *root_fd_out,
                               struct stat *root_stat_out, struct stat *anchors_stat_out) {
  struct stat root_stat;
  struct stat anchors_stat;
  int root_fd = -1;
  int anchors_fd = -1;

  root_fd = open(configuration->anchor_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root_fd < 0) {
    return fail_errno("unsafe runtime directory", configuration->anchor_root);
  }
  if (fstat(root_fd, &root_stat) != 0) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("cannot stat runtime directory", configuration->anchor_root);
  }
  if (!S_ISDIR(root_stat.st_mode) || root_stat.st_uid != getuid() ||
      (root_stat.st_mode & 0777U) != 0700U) {
    errorf("unsafe runtime directory: %s must be a current-UID mode 0700 directory",
           configuration->anchor_root);
    (void)close(root_fd);
    return -1;
  }
  if (mkdirat(root_fd, "anchors", 0700) != 0 && errno != EEXIST) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("cannot create runtime anchors directory", configuration->anchor_root);
  }
  if (fstatat(root_fd, "anchors", &anchors_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("unsafe runtime anchors directory", configuration->anchor_root);
  }
  if (!S_ISDIR(anchors_stat.st_mode) || anchors_stat.st_uid != getuid() ||
      (anchors_stat.st_mode & 0777U) != 0700U) {
    errorf("unsafe runtime anchors directory: %s/anchors must be a current-UID mode 0700 directory",
           configuration->anchor_root);
    (void)close(root_fd);
    return -1;
  }
  anchors_fd = openat(root_fd, "anchors", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (anchors_fd < 0) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("unsafe runtime anchors directory", configuration->anchor_root);
  }
  if (directory_is_empty(anchors_fd) != 0) {
    const int saved_errno = errno;

    (void)close(anchors_fd);
    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("unsafe runtime anchors directory", configuration->anchor_root);
  }
  if (close(anchors_fd) != 0) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("cannot close runtime anchors directory", configuration->anchor_root);
  }
  *root_fd_out = root_fd;
  *root_stat_out = root_stat;
  *anchors_stat_out = anchors_stat;
  return 0;
}

static int write_all(int file_descriptor, const char *text) {
  size_t remaining = strlen(text);
  const char *cursor = text;

  while (remaining > 0U) {
    const ssize_t written = write(file_descriptor, cursor, remaining);

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
    remaining -= (size_t)written;
  }
  return 0;
}

static int write_proc_file(const char *path, const char *text) {
  int file_descriptor = open(path, O_WRONLY | O_CLOEXEC);
  int result;

  if (file_descriptor < 0) {
    return -1;
  }
  result = write_all(file_descriptor, text);
  if (close(file_descriptor) != 0 && result == 0) {
    result = -1;
  }
  return result;
}

static int bubblewrap_failure_errno(const char *stage) {
  const int saved_errno = errno;

  fprintf(stderr, "ocsb: mount anchoring unavailable for bubblewrap: %s: %s\n", stage,
          strerror(saved_errno));
  return -1;
}

static int bubblewrap_failure(const char *message) {
  fprintf(stderr, "ocsb: mount anchoring unavailable for bubblewrap: %s\n", message);
  return -1;
}

static enum open_result call_openat2(int directory_fd, const char *path, uint64_t flags,
                                     int *file_descriptor_out);
static int fail_openat2_unsupported(void);

static void terminate_inherited_bridge(const char *stage) {
  const int saved_errno = errno;

  fprintf(stderr,
          "ocsb: mount anchoring unavailable for bubblewrap: inherited-FD namespace bridge "
          "cannot restore %s: %s\n",
          stage, strerror(saved_errno));
  _exit(1);
}

static int open_inherited_directory_parent(const struct inherited_fd_spec *root,
                                           int *parent_fd_out, struct stat *parent_stat_out) {
  int parent_fd = openat(root->file_descriptor, "..", O_PATH | O_DIRECTORY | O_CLOEXEC);
  struct stat parent_stat;

  if (parent_fd < 0) {
    return bubblewrap_failure_errno("derive inherited directory parent");
  }
  if (fstat(parent_fd, &parent_stat) != 0) {
    const int saved_errno = errno;

    (void)close(parent_fd);
    errno = saved_errno;
    return bubblewrap_failure_errno("stat inherited directory parent");
  }
  if (!S_ISDIR(parent_stat.st_mode)) {
    (void)close(parent_fd);
    return bubblewrap_failure("inherited directory parent is not a directory");
  }
  *parent_fd_out = parent_fd;
  *parent_stat_out = parent_stat;
  return 0;
}

static int collect_inherited_bridge_roots(const struct configuration *configuration,
                                          size_t *project_index_out, size_t *state_index_out,
                                          size_t *regular_index_out, int *common_parent_fd_out) {
  size_t project_index = SIZE_MAX;
  size_t state_index = SIZE_MAX;
  size_t regular_index = SIZE_MAX;
  size_t directory_count = 0U;
  size_t regular_count = 0U;
  size_t index;
  int common_parent_fd = -1;
  struct stat common_parent_stat = { 0 };
  bool have_common_parent = false;
  int result = -1;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const struct inherited_fd_spec *root = &configuration->inherited_roots[index];

    if (root->expected_type == SOURCE_DIRECTORY) {
      struct stat parent_stat;
      int parent_fd = -1;

      ++directory_count;
      if (root->role == INHERITED_ROOT_PROJECT) {
        if (project_index != SIZE_MAX) {
          (void)bubblewrap_failure("duplicate inherited project directory root");
          goto out;
        }
        project_index = index;
      } else if (root->role == INHERITED_ROOT_STATE_BASE) {
        if (state_index != SIZE_MAX) {
          (void)bubblewrap_failure("duplicate inherited state directory root");
          goto out;
        }
        state_index = index;
      } else if (root->role != INHERITED_ROOT_MOUNT) {
        (void)bubblewrap_failure("invalid inherited directory root role");
        goto out;
      }
      if (open_inherited_directory_parent(root, &parent_fd, &parent_stat) != 0) {
        goto out;
      }
      if (!have_common_parent) {
        common_parent_fd = parent_fd;
        common_parent_stat = parent_stat;
        have_common_parent = true;
      } else {
        if (parent_stat.st_dev != common_parent_stat.st_dev ||
            parent_stat.st_ino != common_parent_stat.st_ino || !S_ISDIR(parent_stat.st_mode)) {
          (void)close(parent_fd);
          (void)bubblewrap_failure("inherited directory roots do not share one parent");
          goto out;
        }
        if (close(parent_fd) != 0) {
          (void)bubblewrap_failure_errno("close inherited directory parent");
          goto out;
        }
      }
    } else {
      ++regular_count;
      if (root->role != INHERITED_ROOT_MOUNT || regular_index != SIZE_MAX) {
        (void)bubblewrap_failure("invalid inherited regular root topology");
        goto out;
      }
      regular_index = index;
    }
  }
  if (directory_count != 3U || regular_count != 1U || project_index == SIZE_MAX ||
      state_index == SIZE_MAX || regular_index == SIZE_MAX || common_parent_fd < 0) {
    (void)bubblewrap_failure("inherited-FD namespace bridge requires three directory roots and one regular root");
    goto out;
  }
  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    size_t other_index;
    const struct inherited_fd_spec *root = &configuration->inherited_roots[index];

    if (root->expected_type != SOURCE_DIRECTORY) {
      continue;
    }
    for (other_index = index + 1U; other_index < configuration->inherited_root_count;
         ++other_index) {
      const struct inherited_fd_spec *other = &configuration->inherited_roots[other_index];

      if (other->expected_type == SOURCE_DIRECTORY && root->expected_dev == other->expected_dev &&
          root->expected_ino == other->expected_ino) {
        (void)bubblewrap_failure("duplicate inherited directory root identity");
        goto out;
      }
    }
  }
  *project_index_out = project_index;
  *state_index_out = state_index;
  *regular_index_out = regular_index;
  *common_parent_fd_out = common_parent_fd;
  common_parent_fd = -1;
  result = 0;

out:
  if (common_parent_fd >= 0) {
    (void)close(common_parent_fd);
  }
  return result;
}

static int translated_directory_root_index(const struct configuration *configuration,
                                           const struct stat *status, size_t *index_out) {
  size_t index;
  size_t match_index = SIZE_MAX;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const struct inherited_fd_spec *root = &configuration->inherited_roots[index];

    if (root->expected_type == SOURCE_DIRECTORY && root->expected_dev == status->st_dev &&
        root->expected_ino == status->st_ino) {
      if (match_index != SIZE_MAX) {
        return bubblewrap_failure("ambiguous inherited directory root identity");
      }
      match_index = index;
    }
  }
  *index_out = match_index;
  return 0;
}

static int scan_translated_directory_roots(const struct configuration *configuration,
                                           int translated_parent_fd, int *translated_fds) {
  DIR *directory = NULL;
  int scan_fd = -1;
  int result = -1;

  scan_fd = fcntl(translated_parent_fd, F_DUPFD_CLOEXEC, 3);
  if (scan_fd < 0) {
    return bubblewrap_failure_errno("duplicate translated inherited parent");
  }
  directory = fdopendir(scan_fd);
  if (directory == NULL) {
    const int saved_errno = errno;

    (void)close(scan_fd);
    errno = saved_errno;
    return bubblewrap_failure_errno("enumerate translated inherited parent");
  }
  for (;;) {
    struct dirent *entry;
    struct stat entry_stat;
    int candidate_fd = -1;
    size_t root_index;
    enum open_result open_result;

    errno = 0;
    entry = readdir(directory);
    if (entry == NULL) {
      if (errno != 0) {
        (void)bubblewrap_failure_errno("enumerate translated inherited parent");
        goto out;
      }
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (fstatat(dirfd(directory), entry->d_name, &entry_stat, AT_SYMLINK_NOFOLLOW) != 0) {
      (void)bubblewrap_failure_errno("inspect translated inherited parent entry");
      goto out;
    }
    if (S_ISLNK(entry_stat.st_mode)) {
      errno = ELOOP;
      (void)bubblewrap_failure("translated inherited parent contains a symlink");
      goto out;
    }
    if (!S_ISDIR(entry_stat.st_mode)) {
      continue;
    }
    open_result = call_openat2(dirfd(directory), entry->d_name,
                               O_PATH | O_DIRECTORY | O_CLOEXEC, &candidate_fd);
    if (open_result == OPEN_RESULT_UNSUPPORTED) {
      (void)fail_openat2_unsupported();
      goto out;
    }
    if (open_result != OPEN_RESULT_OK) {
      (void)bubblewrap_failure_errno("open translated inherited parent entry");
      goto out;
    }
    if (fstat(candidate_fd, &entry_stat) != 0 || !S_ISDIR(entry_stat.st_mode)) {
      const int saved_errno = errno == 0 ? EIO : errno;

      (void)close(candidate_fd);
      errno = saved_errno;
      (void)bubblewrap_failure_errno("validate translated inherited directory entry");
      goto out;
    }
    if (translated_directory_root_index(configuration, &entry_stat, &root_index) != 0) {
      (void)close(candidate_fd);
      goto out;
    }
    if (root_index == SIZE_MAX) {
      if (close(candidate_fd) != 0) {
        (void)bubblewrap_failure_errno("close nonmatching translated inherited directory");
        goto out;
      }
      continue;
    }
    if (translated_fds[root_index] >= 0) {
      (void)close(candidate_fd);
      (void)bubblewrap_failure("duplicate translated inherited directory root");
      goto out;
    }
    translated_fds[root_index] = candidate_fd;
  }
  {
    size_t index;

    for (index = 0U; index < configuration->inherited_root_count; ++index) {
      if (configuration->inherited_roots[index].expected_type == SOURCE_DIRECTORY &&
          translated_fds[index] < 0) {
        (void)bubblewrap_failure("missing translated inherited directory root");
        goto out;
      }
    }
  }
  result = 0;

out:
  if (directory != NULL && closedir(directory) != 0 && result == 0) {
    return bubblewrap_failure_errno("close translated inherited parent enumeration");
  }
  return result;
}

static int scan_translated_regular_root(const struct configuration *configuration,
                                        size_t state_index, size_t regular_index,
                                        int *translated_fds) {
  const struct inherited_fd_spec *regular_root = &configuration->inherited_roots[regular_index];
  DIR *directory = NULL;
  int state_fd = -1;
  int result = -1;
  enum open_result open_result;

  open_result = call_openat2(translated_fds[state_index], ".",
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC, &state_fd);
  if (open_result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (open_result != OPEN_RESULT_OK) {
    return bubblewrap_failure_errno("open translated inherited state root");
  }
  directory = fdopendir(state_fd);
  if (directory == NULL) {
    const int saved_errno = errno;

    (void)close(state_fd);
    errno = saved_errno;
    return bubblewrap_failure_errno("enumerate translated inherited state root");
  }
  for (;;) {
    struct dirent *entry;
    struct stat entry_stat;
    int candidate_fd = -1;

    errno = 0;
    entry = readdir(directory);
    if (entry == NULL) {
      if (errno != 0) {
        (void)bubblewrap_failure_errno("enumerate translated inherited state root");
        goto out;
      }
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (fstatat(dirfd(directory), entry->d_name, &entry_stat, AT_SYMLINK_NOFOLLOW) != 0) {
      (void)bubblewrap_failure_errno("inspect translated inherited state entry");
      goto out;
    }
    if (S_ISLNK(entry_stat.st_mode)) {
      errno = ELOOP;
      (void)bubblewrap_failure("translated inherited state root contains a symlink");
      goto out;
    }
    if (entry_stat.st_dev != regular_root->expected_dev ||
        entry_stat.st_ino != regular_root->expected_ino) {
      continue;
    }
    if (!S_ISREG(entry_stat.st_mode)) {
      (void)bubblewrap_failure("translated inherited regular root has the wrong type");
      goto out;
    }
    open_result = call_openat2(dirfd(directory), entry->d_name, O_PATH | O_CLOEXEC, &candidate_fd);
    if (open_result == OPEN_RESULT_UNSUPPORTED) {
      (void)fail_openat2_unsupported();
      goto out;
    }
    if (open_result != OPEN_RESULT_OK) {
      (void)bubblewrap_failure_errno("open translated inherited regular entry");
      goto out;
    }
    if (fstat(candidate_fd, &entry_stat) != 0 || !S_ISREG(entry_stat.st_mode) ||
        entry_stat.st_dev != regular_root->expected_dev ||
        entry_stat.st_ino != regular_root->expected_ino) {
      const int saved_errno = errno == 0 ? EIO : errno;

      (void)close(candidate_fd);
      errno = saved_errno;
      (void)bubblewrap_failure_errno("validate translated inherited regular entry");
      goto out;
    }
    if (translated_fds[regular_index] >= 0) {
      (void)close(candidate_fd);
      (void)bubblewrap_failure("duplicate translated inherited regular root");
      goto out;
    }
    translated_fds[regular_index] = candidate_fd;
  }
  if (translated_fds[regular_index] < 0) {
    (void)bubblewrap_failure("missing translated inherited regular root");
    goto out;
  }
  result = 0;

out:
  if (directory != NULL && closedir(directory) != 0 && result == 0) {
    return bubblewrap_failure_errno("close translated inherited state enumeration");
  }
  return result;
}

static int establish_bubblewrap_mount_namespace(const char *private_mount_target,
                                                bool namespace_already_unshared) {
  if (!namespace_already_unshared && unshare(CLONE_NEWNS) != 0) {
    return bubblewrap_failure_errno("unshare(CLONE_NEWNS)");
  }
  if (mount(NULL, private_mount_target, NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    return bubblewrap_failure_errno("make mount namespace private");
  }
  return 0;
}

static int translate_inherited_roots_into_bubblewrap_namespace(
    struct configuration *configuration, int *original_cwd_fd) {
  size_t project_index;
  size_t state_index;
  size_t regular_index;
  size_t index;
  int common_parent_fd = -1;
  int old_root_fd = -1;
  int translated_parent_fd = -1;
  int translated_cwd_fd = -1;
  int *translated_fds = NULL;
  bool bridge_root_changed = false;
  bool bridge_cwd_is_old_root = false;
  bool original_cwd_replaced = false;
  int result = -1;

  if (*original_cwd_fd < 0) {
    return bubblewrap_failure("missing inherited wrapper current working directory");
  }
  translated_fds = calloc(configuration->inherited_root_count, sizeof(*translated_fds));
  if (translated_fds == NULL) {
    return bubblewrap_failure("cannot allocate inherited-FD namespace bridge state");
  }
  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    translated_fds[index] = -1;
  }
  if (collect_inherited_bridge_roots(configuration, &project_index, &state_index, &regular_index,
                                     &common_parent_fd) != 0) {
    goto out;
  }
  old_root_fd = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (old_root_fd < 0) {
    (void)bubblewrap_failure_errno("preserve filesystem root for inherited-FD namespace bridge");
    goto out;
  }
  if (fchdir(common_parent_fd) != 0) {
    (void)bubblewrap_failure_errno("enter inherited directory parent for namespace bridge");
    goto out;
  }
  if (chroot(".") != 0) {
    (void)bubblewrap_failure_errno("chroot to inherited directory parent for namespace bridge");
    goto out;
  }
  bridge_root_changed = true;
  if (fchdir(old_root_fd) != 0) {
    terminate_inherited_bridge("old filesystem root");
  }
  bridge_cwd_is_old_root = true;
  if (establish_bubblewrap_mount_namespace(".", false) != 0) {
    goto out;
  }
  translated_parent_fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (translated_parent_fd < 0) {
    (void)bubblewrap_failure_errno("open translated inherited directory parent");
    goto out;
  }
  if (scan_translated_directory_roots(configuration, translated_parent_fd, translated_fds) != 0 ||
      scan_translated_regular_root(configuration, state_index, regular_index, translated_fds) != 0) {
    goto out;
  }
  if (chroot(".") != 0) {
    terminate_inherited_bridge("old filesystem root after namespace translation");
  }
  bridge_root_changed = false;
  if (fchdir(translated_fds[project_index]) != 0) {
    (void)bubblewrap_failure_errno("enter translated inherited project root");
    goto out;
  }
  translated_cwd_fd = fcntl(translated_fds[project_index], F_DUPFD_CLOEXEC, 3);
  if (translated_cwd_fd < 0) {
    (void)bubblewrap_failure_errno("preserve translated inherited project root");
    goto out;
  }
  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const int old_fd = configuration->inherited_roots[index].file_descriptor;

    configuration->inherited_roots[index].file_descriptor = translated_fds[index];
    translated_fds[index] = -1;
    if (close(old_fd) != 0) {
      (void)bubblewrap_failure_errno("close foreign inherited root descriptor");
      goto out;
    }
  }
  {
    const int old_cwd_fd = *original_cwd_fd;

    *original_cwd_fd = translated_cwd_fd;
    translated_cwd_fd = -1;
    original_cwd_replaced = true;
    if (close(old_cwd_fd) != 0) {
      (void)bubblewrap_failure_errno("close foreign wrapper current working directory");
      goto out;
    }
  }
  result = 0;

out:
  if (bridge_root_changed) {
    if (!bridge_cwd_is_old_root || chroot(".") != 0) {
      terminate_inherited_bridge("filesystem root after inherited-FD bridge failure");
    }
    bridge_root_changed = false;
  }
  if (result != 0 && !original_cwd_replaced && fchdir(*original_cwd_fd) != 0) {
    terminate_inherited_bridge("wrapper current working directory after inherited-FD bridge failure");
  }
  if (translated_parent_fd >= 0) {
    if (close(translated_parent_fd) != 0 && result == 0) {
      (void)bubblewrap_failure_errno("close translated inherited directory parent");
      result = -1;
    }
    translated_parent_fd = -1;
  }
  if (old_root_fd >= 0) {
    if (close(old_root_fd) != 0 && result == 0) {
      (void)bubblewrap_failure_errno("close preserved filesystem root");
      result = -1;
    }
    old_root_fd = -1;
  }
  if (common_parent_fd >= 0) {
    if (close(common_parent_fd) != 0 && result == 0) {
      (void)bubblewrap_failure_errno("close foreign inherited directory parent");
      result = -1;
    }
    common_parent_fd = -1;
  }
  if (translated_cwd_fd >= 0) {
    (void)close(translated_cwd_fd);
  }
  if (translated_fds != NULL) {
    for (index = 0U; index < configuration->inherited_root_count; ++index) {
      if (translated_fds[index] >= 0) {
        (void)close(translated_fds[index]);
      }
    }
  }
  free(translated_fds);
  return result;
}

static int setup_bubblewrap_namespace(struct configuration *configuration, int *original_cwd_fd) {
  char uid_map[128];
  char gid_map[128];
  char root_uid_map[128];
  char root_gid_map[128];
  int uid_map_length;
  int gid_map_length;
  int root_uid_map_length;
  int root_gid_map_length;

  if (unshare(CLONE_NEWUSER |
              (configuration->inherited_root_count == 0U ? CLONE_NEWNS : 0)) != 0) {
    return configuration->inherited_root_count == 0U
               ? bubblewrap_failure_errno("unshare(CLONE_NEWUSER|CLONE_NEWNS)")
               : bubblewrap_failure_errno("unshare(CLONE_NEWUSER)");
  }
  if (write_proc_file("/proc/self/setgroups", "deny\n") != 0 && errno != ENOENT &&
      errno != EACCES && errno != EPERM) {
    return bubblewrap_failure_errno("write /proc/self/setgroups");
  }
  uid_map_length = snprintf(uid_map, sizeof(uid_map), "%" PRIuMAX " %" PRIuMAX " 1\n",
                            (uintmax_t)configuration->host_uid,
                            (uintmax_t)configuration->host_uid);
  gid_map_length = snprintf(gid_map, sizeof(gid_map), "%" PRIuMAX " %" PRIuMAX " 1\n",
                            (uintmax_t)configuration->host_gid,
                            (uintmax_t)configuration->host_gid);
  root_uid_map_length = snprintf(root_uid_map, sizeof(root_uid_map), "0 %" PRIuMAX " 1\n",
                                 (uintmax_t)configuration->host_uid);
  root_gid_map_length = snprintf(root_gid_map, sizeof(root_gid_map), "0 %" PRIuMAX " 1\n",
                                 (uintmax_t)configuration->host_gid);
  if (uid_map_length < 0 || (size_t)uid_map_length >= sizeof(uid_map) || gid_map_length < 0 ||
      (size_t)gid_map_length >= sizeof(gid_map) || root_uid_map_length < 0 ||
      (size_t)root_uid_map_length >= sizeof(root_uid_map) || root_gid_map_length < 0 ||
      (size_t)root_gid_map_length >= sizeof(root_gid_map)) {
    return bubblewrap_failure("cannot format user namespace identity maps");
  }
  if (write_root_map_or_identity_fallback("/proc/self/uid_map", root_uid_map, uid_map,
                                          (uintmax_t)configuration->host_uid,
                                          "write /proc/self/uid_map") != 0) {
    return -1;
  }
  if (write_root_map_or_identity_fallback("/proc/self/gid_map", root_gid_map, gid_map,
                                          (uintmax_t)configuration->host_gid,
                                          "write /proc/self/gid_map") != 0) {
    return -1;
  }
  if (getuid() != configuration->host_uid || getgid() != configuration->host_gid) {
    configuration->bubblewrap_rewrite_identity = true;
    configuration->bubblewrap_uid = getuid();
    configuration->bubblewrap_gid = getgid();
  }
  if (configuration->inherited_root_count != 0U) {
    return translate_inherited_roots_into_bubblewrap_namespace(configuration, original_cwd_fd);
  }
  return establish_bubblewrap_mount_namespace("/", configuration->inherited_root_count == 0U);
}

static int has_effective_cap_sys_admin(void) {
#ifdef SYS_capget
  struct __user_cap_header_struct header = {
    .version = _LINUX_CAPABILITY_VERSION_3,
    .pid = 0,
  };
  struct __user_cap_data_struct data[2] = { { 0U, 0U, 0U }, { 0U, 0U, 0U } };
  const unsigned int capability_index = CAP_SYS_ADMIN / 32U;
  const unsigned int capability_bit = CAP_SYS_ADMIN % 32U;

  if (syscall(SYS_capget, &header, &data) != 0) {
    return -1;
  }
  if (capability_index >= sizeof(data) / sizeof(data[0])) {
    errno = EOVERFLOW;
    return -1;
  }
  return (data[capability_index].effective & (1U << capability_bit)) != 0U ? 1 : 0;
#else
  errno = ENOSYS;
  return -1;
#endif
}

static int nspawn_privilege_failure(void) {
  fputs("ocsb: backend 'systemd-nspawn' cannot establish private mount anchors; run with "
        "mount-namespace privilege or use bubblewrap\n",
        stderr);
  return -1;
}

static int setup_current_namespace(const struct configuration *configuration) {
  const int has_capability = has_effective_cap_sys_admin();

  if (configuration->backend == BACKEND_NSPAWN && geteuid() != 0 && has_capability != 1) {
    return nspawn_privilege_failure();
  }
  if (has_capability != 1) {
    if (configuration->backend == BACKEND_NSPAWN) {
      return nspawn_privilege_failure();
    }
    if (has_capability < 0) {
      return fail_errno("mount anchoring unavailable: cannot inspect effective CAP_SYS_ADMIN", NULL);
    }
    errorf("mount anchoring unavailable: effective CAP_SYS_ADMIN is required");
    return -1;
  }
  if (unshare(CLONE_NEWNS) != 0 || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    if (configuration->backend == BACKEND_NSPAWN) {
      return nspawn_privilege_failure();
    }
    return fail_errno("mount anchoring unavailable: cannot establish private mount namespace", NULL);
  }
  return 0;
}

static int setup_namespace(struct configuration *configuration, int *original_cwd_fd) {
  if (configuration->namespace_mode == NAMESPACE_BUBBLEWRAP_USER) {
    return setup_bubblewrap_namespace(configuration, original_cwd_fd);
  }
  return setup_current_namespace(configuration);
}

static enum open_result call_openat2(int directory_fd, const char *path, uint64_t flags,
                                     int *file_descriptor_out) {
#ifdef SYS_openat2
  struct open_how how = {
    .flags = flags,
    .mode = 0U,
    .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
  };
  const int file_descriptor =
      (int)syscall(SYS_openat2, directory_fd, path, &how, sizeof(how));

  if (file_descriptor >= 0) {
    *file_descriptor_out = file_descriptor;
    return OPEN_RESULT_OK;
  }
  if (errno == ENOSYS || errno == EINVAL) {
    return OPEN_RESULT_UNSUPPORTED;
  }
  if (errno == ENOENT) {
    return OPEN_RESULT_ABSENT;
  }
  return OPEN_RESULT_ERROR;
#else
  (void)directory_fd;
  (void)path;
  (void)flags;
  (void)file_descriptor_out;
  return OPEN_RESULT_UNSUPPORTED;
#endif
}

static enum open_result open_relative_components(int base_fd, const char *relative_path,
                                                 uint64_t final_flags, int *file_descriptor_out) {
  const char *cursor = relative_path;
  int current_fd = -1;
  enum open_result result;

  while (*cursor == '/') {
    ++cursor;
  }
  if (*cursor == '\0') {
    return call_openat2(base_fd, ".", final_flags, file_descriptor_out);
  }
  while (*cursor != '\0') {
    const char *component_start = cursor;
    const char *component_end;
    const char *after_component;
    size_t component_length;
    char component[NAME_MAX + 1U];
    int opened_fd = -1;
    uint64_t flags;

    while (*cursor != '\0' && *cursor != '/') {
      ++cursor;
    }
    component_end = cursor;
    while (*cursor == '/') {
      ++cursor;
    }
    after_component = cursor;
    component_length = (size_t)(component_end - component_start);
    if (component_length == 0U) {
      continue;
    }
    if (component_length > NAME_MAX) {
      errno = ENAMETOOLONG;
      result = OPEN_RESULT_ERROR;
      goto out;
    }
    memcpy(component, component_start, component_length);
    component[component_length] = '\0';
    flags = *after_component == '\0' ? final_flags : (O_PATH | O_DIRECTORY | O_CLOEXEC);
    result = call_openat2(current_fd >= 0 ? current_fd : base_fd, component, flags, &opened_fd);
    if (result != OPEN_RESULT_OK) {
      goto out;
    }
    if (current_fd >= 0 && close(current_fd) != 0) {
      const int saved_errno = errno;

      (void)close(opened_fd);
      errno = saved_errno;
      result = OPEN_RESULT_ERROR;
      goto out;
    }
    current_fd = opened_fd;
  }
  *file_descriptor_out = current_fd;
  return OPEN_RESULT_OK;

out:
  if (current_fd >= 0) {
    (void)close(current_fd);
  }
  return result;
}

static enum open_result open_containment_root(const char *path, int *file_descriptor_out) {
  int slash_fd;
  enum open_result result;

  slash_fd = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (slash_fd < 0) {
    return OPEN_RESULT_ERROR;
  }
  result = open_relative_components(slash_fd, path + 1, O_PATH | O_DIRECTORY | O_CLOEXEC,
                                    file_descriptor_out);
  if (close(slash_fd) != 0 && result == OPEN_RESULT_OK) {
    const int saved_errno = errno;

    (void)close(*file_descriptor_out);
    *file_descriptor_out = -1;
    errno = saved_errno;
    return OPEN_RESULT_ERROR;
  }
  return result;
}

static int reopen_anchor_root_in_namespace(const struct configuration *configuration,
                                           const struct stat *expected_root_stat,
                                           int *root_fd_out) {
  struct stat root_stat;
  int root_fd = -1;
  enum open_result result = open_containment_root(configuration->anchor_root, &root_fd);

  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("unsafe runtime directory", configuration->anchor_root);
  }
  if (fstat(root_fd, &root_stat) != 0) {
    const int saved_errno = errno;

    (void)close(root_fd);
    errno = saved_errno;
    return fail_errno("cannot stat runtime directory", configuration->anchor_root);
  }
  if (!S_ISDIR(root_stat.st_mode) || root_stat.st_uid != getuid() ||
      (root_stat.st_mode & 0777U) != 0700U || root_stat.st_dev != expected_root_stat->st_dev ||
      root_stat.st_ino != expected_root_stat->st_ino) {
    errorf("unsafe runtime directory changed before namespace mount: %s",
           configuration->anchor_root);
    (void)close(root_fd);
    return -1;
  }
  *root_fd_out = root_fd;
  return 0;
}

static int relative_source_path(const struct source_spec *source, const char **relative_out) {
  size_t root_length = strlen(source->containment_root);
  const char *source_path = source->absolute_path;

  while (root_length > 1U && source->containment_root[root_length - 1U] == '/') {
    --root_length;
  }
  if (root_length == 1U && source->containment_root[0] == '/') {
    *relative_out = source_path + 1;
    return 0;
  }
  if (strncmp(source_path, source->containment_root, root_length) != 0 ||
      (source_path[root_length] != '\0' && source_path[root_length] != '/')) {
    errorf("unsafe host path: outside containment root: %s", source->absolute_path);
    return -1;
  }
  *relative_out = source_path + root_length;
  while (**relative_out == '/') {
    ++*relative_out;
  }
  return 0;
}

static int fail_openat2_unsupported(void) {
  fputs("ocsb: mount anchoring unavailable: openat2 RESOLVE_* unsupported\n", stderr);
  return -1;
}

static bool inherited_root_relative_path(const struct inherited_fd_spec *root, const char *path,
                                         const char **relative_out) {
  const size_t root_length = strlen(root->display_path);

  if (strcmp(root->display_path, "/") == 0) {
    if (path[0] != '/') {
      return false;
    }
    *relative_out = path + 1;
    return true;
  }
  if (strncmp(root->display_path, path, root_length) != 0 ||
      (path[root_length] != '\0' && path[root_length] != '/')) {
    return false;
  }
  *relative_out = path + root_length;
  if (**relative_out == '/') {
    ++*relative_out;
  }
  return true;
}

static int select_inherited_root(const struct configuration *configuration, const char *path,
                                 bool restrict_role, enum inherited_root_role role,
                                 const struct inherited_fd_spec **root_out,
                                 const char **relative_out) {
  const struct inherited_fd_spec *selected = NULL;
  const char *selected_relative = NULL;
  size_t selected_length = 0U;
  size_t index;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    const struct inherited_fd_spec *candidate = &configuration->inherited_roots[index];
    const char *relative;

    if (restrict_role && candidate->role != role) {
      continue;
    }
    if (!inherited_root_relative_path(candidate, path, &relative)) {
      continue;
    }
    if (candidate->expected_type == SOURCE_REGULAR) {
      if (*relative != '\0') {
        errorf("inherited regular root cannot contain descendants: %s", candidate->display_path);
        errno = ENOTDIR;
        return -1;
      }
      selected = candidate;
      selected_relative = relative;
      selected_length = strlen(candidate->display_path);
      continue;
    }
    if (selected == NULL || selected->expected_type != SOURCE_REGULAR ||
        strlen(candidate->display_path) > selected_length) {
      selected = candidate;
      selected_relative = relative;
      selected_length = strlen(candidate->display_path);
    }
  }
  *root_out = selected;
  *relative_out = selected_relative;
  return 0;
}

static enum open_result open_from_inherited_root(
    const struct configuration *configuration, const char *path, bool restrict_role,
    enum inherited_root_role role, uint64_t final_flags, int *file_descriptor_out, bool *matched_out) {
  const struct inherited_fd_spec *root;
  const char *relative;
  int duplicate_fd;
  enum open_result result;

  *matched_out = false;
  if (select_inherited_root(configuration, path, restrict_role, role, &root, &relative) != 0) {
    return OPEN_RESULT_ERROR;
  }
  if (root == NULL) {
    return OPEN_RESULT_OK;
  }
  duplicate_fd = fcntl(root->file_descriptor, F_DUPFD_CLOEXEC, 3);
  if (duplicate_fd < 0) {
    return OPEN_RESULT_ERROR;
  }
  if (*relative == '\0') {
    if (root->expected_type == SOURCE_DIRECTORY) {
      result = call_openat2(duplicate_fd, ".", final_flags, file_descriptor_out);
      if (close(duplicate_fd) != 0 && result == OPEN_RESULT_OK) {
        const int saved_errno = errno;

        (void)close(*file_descriptor_out);
        *file_descriptor_out = -1;
        errno = saved_errno;
        return OPEN_RESULT_ERROR;
      }
      if (result == OPEN_RESULT_OK) {
        *matched_out = true;
      }
      return result;
    }
    *file_descriptor_out = duplicate_fd;
    *matched_out = true;
    return OPEN_RESULT_OK;
  }
  result = open_relative_components(duplicate_fd, relative, final_flags, file_descriptor_out);
  if (close(duplicate_fd) != 0 && result == OPEN_RESULT_OK) {
    const int saved_errno = errno;

    (void)close(*file_descriptor_out);
    *file_descriptor_out = -1;
    errno = saved_errno;
    return OPEN_RESULT_ERROR;
  }
  if (result == OPEN_RESULT_OK) {
    *matched_out = true;
  }
  return result;
}

static int open_one_source(const struct configuration *configuration, struct source_spec *source) {
  int containment_fd = -1;
  int source_fd = -1;
  const char *relative_path;
  struct stat status;
  enum open_result result;
  bool inherited_match = false;

  if (relative_source_path(source, &relative_path) != 0) {
    return -1;
  }
  result = open_from_inherited_root(configuration, source->absolute_path, false,
                                    INHERITED_ROOT_MOUNT, O_PATH | O_CLOEXEC, &source_fd,
                                    &inherited_match);
  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result == OPEN_RESULT_ABSENT && source->requiredness == SOURCE_OPTIONAL) {
    source->absent = true;
    return 0;
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("unsafe host path: cannot derive from inherited root", source->absolute_path);
  }

  if (!inherited_match) {
    result = open_containment_root(source->containment_root, &containment_fd);
    if (result == OPEN_RESULT_UNSUPPORTED) {
      return fail_openat2_unsupported();
    }
    if (result == OPEN_RESULT_ABSENT && source->requiredness == SOURCE_OPTIONAL) {
      source->absent = true;
      return 0;
    }
    if (result != OPEN_RESULT_OK) {
      return fail_errno("unsafe host path: cannot open containment root", source->containment_root);
    }
    result = open_relative_components(containment_fd, relative_path, O_PATH | O_CLOEXEC, &source_fd);
    if (close(containment_fd) != 0 && result == OPEN_RESULT_OK) {
      const int saved_errno = errno;

      (void)close(source_fd);
      errno = saved_errno;
      return fail_errno("unsafe host path: cannot close containment root", source->containment_root);
    }
    if (result == OPEN_RESULT_UNSUPPORTED) {
      return fail_openat2_unsupported();
    }
    if (result == OPEN_RESULT_ABSENT && source->requiredness == SOURCE_OPTIONAL) {
      source->absent = true;
      return 0;
    }
    if (result != OPEN_RESULT_OK) {
      return fail_errno("unsafe host path: cannot open", source->absolute_path);
    }
  }
  if (fstat(source_fd, &status) != 0) {
    const int saved_errno = errno;

    (void)close(source_fd);
    errno = saved_errno;
    return fail_errno("unsafe host path: cannot stat", source->absolute_path);
  }
  if (status.st_dev != source->expected_dev || status.st_ino != source->expected_ino ||
      (source->expected_type == SOURCE_DIRECTORY && !S_ISDIR(status.st_mode)) ||
      (source->expected_type == SOURCE_REGULAR && !S_ISREG(status.st_mode))) {
    fprintf(stderr, "ocsb: unsafe host path: identity changed: %s\n", source->absolute_path);
    (void)close(source_fd);
    return -1;
  }
  source->source_fd = source_fd;
  return 0;
}

static int open_sources(struct configuration *configuration) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    if (open_one_source(configuration, &configuration->sources[index]) != 0) {
      return -1;
    }
  }
  return 0;
}

static int dup_directory_fd(int file_descriptor, int *duplicate_out) {
  const int duplicate = fcntl(file_descriptor, F_DUPFD_CLOEXEC, 3);

  if (duplicate < 0) {
    return -1;
  }
  *duplicate_out = duplicate;
  return 0;
}

static int open_absolute_directory(const char *path, int *file_descriptor_out) {
  int slash_fd = -1;
  int directory_fd = -1;
  enum open_result result;

  slash_fd = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (slash_fd < 0) {
    return fail_errno("workspace protocol: cannot open filesystem root", NULL);
  }
  result = open_relative_components(slash_fd, path + 1,
                                    O_RDONLY | O_DIRECTORY | O_CLOEXEC, &directory_fd);
  if (close(slash_fd) != 0 && result == OPEN_RESULT_OK) {
    const int saved_errno = errno;

    (void)close(directory_fd);
    errno = saved_errno;
    return fail_errno("workspace protocol: cannot close filesystem root", NULL);
  }
  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("workspace protocol: cannot open directory", path);
  }
  *file_descriptor_out = directory_fd;
  return 0;
}

static int open_workspace_directory(const struct configuration *configuration,
                                    enum inherited_root_role role, const char *path,
                                    const char *label, int *file_descriptor_out,
                                    bool *from_inherited_out) {
  int directory_fd = -1;
  bool inherited_match = false;
  enum open_result result =
      open_from_inherited_root(configuration, path, true, role,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC, &directory_fd,
                               &inherited_match);

  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("workspace protocol: cannot derive directory from inherited root", label);
  }
  if (!inherited_match) {
    if (configuration->inherited_root_count != 0U) {
      errorf("workspace protocol: missing inherited root for %s", label);
      return -1;
    }
    if (open_absolute_directory(path, &directory_fd) != 0) {
      return -1;
    }
  }
  *file_descriptor_out = directory_fd;
  if (from_inherited_out != NULL) {
    *from_inherited_out = inherited_match;
  }
  return 0;
}

static int validate_directory_identity(int file_descriptor, dev_t expected_dev, ino_t expected_ino,
                                       const char *label) {
  struct stat status;

  if (fstat(file_descriptor, &status) != 0) {
    return fail_errno("workspace protocol: cannot stat", label);
  }
  if (!S_ISDIR(status.st_mode) || status.st_dev != expected_dev || status.st_ino != expected_ino) {
    errorf("workspace protocol: identity changed: %s", label);
    return -1;
  }
  return 0;
}

static int open_directory_component(int parent_fd, const char *name, bool create,
                                    int *file_descriptor_out) {
  int directory_fd = -1;
  enum open_result result =
      call_openat2(parent_fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC, &directory_fd);

  if (result == OPEN_RESULT_ABSENT && create) {
    if (mkdirat(parent_fd, name, 0700) != 0 && errno != EEXIST) {
      return -1;
    }
    result = call_openat2(parent_fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC, &directory_fd);
  }
  if (result == OPEN_RESULT_UNSUPPORTED) {
    (void)fail_openat2_unsupported();
    return -1;
  }
  if (result != OPEN_RESULT_OK) {
    return -1;
  }
  *file_descriptor_out = directory_fd;
  return 0;
}

static int open_base_directory(int project_fd, const char *base, bool create, int *base_fd_out) {
  const char *cursor = base;
  int current_fd = -1;

  if (dup_directory_fd(project_fd, &current_fd) != 0) {
    return -1;
  }
  while (*cursor != '\0') {
    const char *component_start = cursor;
    size_t component_length = 0U;
    char component[NAME_MAX + 1U];
    int next_fd = -1;

    while (cursor[component_length] != '\0' && cursor[component_length] != '/') {
      ++component_length;
    }
    memcpy(component, component_start, component_length);
    component[component_length] = '\0';
    if (!is_safe_component(component) ||
        open_directory_component(current_fd, component, create, &next_fd) != 0) {
      const int saved_errno = errno;

      (void)close(current_fd);
      errno = saved_errno;
      return -1;
    }
    if (close(current_fd) != 0) {
      const int saved_errno = errno;

      (void)close(next_fd);
      errno = saved_errno;
      return -1;
    }
    current_fd = next_fd;
    cursor += component_length;
    if (*cursor == '/') {
      ++cursor;
    }
  }
  *base_fd_out = current_fd;
  return 0;
}

static void close_workspace_tree(struct workspace_tree *tree) {
  if (tree->workspace_fd >= 0) {
    (void)close(tree->workspace_fd);
  }
  if (tree->base_fd >= 0) {
    (void)close(tree->base_fd);
  }
  if (tree->project_fd >= 0) {
    (void)close(tree->project_fd);
  }
  tree->project_fd = -1;
  tree->base_fd = -1;
  tree->workspace_fd = -1;
}

static int open_workspace_tree(const struct configuration *configuration,
                               const struct workspace_mutation_spec *spec,
                               struct workspace_tree *tree) {
  int existing_workspace_fd = -1;
  enum open_result workspace_result;
  const bool create_base = spec->action != WORKSPACE_ACTION_CONTINUE;

  *tree = (struct workspace_tree){ .project_fd = -1, .base_fd = -1, .workspace_fd = -1 };
  if (open_workspace_directory(configuration, INHERITED_ROOT_PROJECT, spec->project, spec->project,
                               &tree->project_fd, &tree->project_from_inherited_root) != 0 ||
      validate_directory_identity(tree->project_fd, spec->project_dev, spec->project_ino,
                                  spec->project) != 0) {
    goto failure;
  }
  if (open_base_directory(tree->project_fd, spec->base, create_base, &tree->base_fd) != 0) {
    (void)fail_errno("workspace protocol: cannot open base directory", spec->base);
    goto failure;
  }
  workspace_result = call_openat2(tree->base_fd, spec->workspace,
                                  O_RDONLY | O_DIRECTORY | O_CLOEXEC, &existing_workspace_fd);
  if (workspace_result == OPEN_RESULT_UNSUPPORTED) {
    (void)fail_openat2_unsupported();
    goto failure;
  }
  if (spec->action == WORKSPACE_ACTION_CREATE && workspace_result == OPEN_RESULT_OK) {
    errorf("workspace protocol: create requires an absent workspace: %s", spec->workspace);
    (void)close(existing_workspace_fd);
    goto failure;
  }
  if (workspace_result == OPEN_RESULT_OK) {
    tree->workspace_fd = existing_workspace_fd;
    return 0;
  }
  if (workspace_result != OPEN_RESULT_ABSENT) {
    (void)fail_errno("workspace protocol: cannot open workspace", spec->workspace);
    goto failure;
  }
  if (spec->action == WORKSPACE_ACTION_CONTINUE) {
    errorf("workspace protocol: continue requires an existing workspace: %s", spec->workspace);
    goto failure;
  }
  if (mkdirat(tree->base_fd, spec->workspace, 0700) != 0) {
    (void)fail_errno("workspace protocol: cannot create workspace", spec->workspace);
    goto failure;
  }
  if (open_directory_component(tree->base_fd, spec->workspace, false, &tree->workspace_fd) != 0) {
    (void)fail_errno("workspace protocol: cannot reopen created workspace", spec->workspace);
    goto failure;
  }
  tree->workspace_created = true;
  return 0;

failure:
  close_workspace_tree(tree);
  return -1;
}

static int remove_tree_entry_nofollow(int parent_fd, const char *name, dev_t root_dev) {
  struct stat before;

  if (fstatat(parent_fd, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
    return -1;
  }
  if (before.st_dev != root_dev) {
    errno = EXDEV;
    return -1;
  }
  if (S_ISDIR(before.st_mode)) {
    DIR *directory;
    struct dirent *entry;
    int child_fd = -1;

    if (open_directory_component(parent_fd, name, false, &child_fd) != 0) {
      return -1;
    }
    if (fstat(child_fd, &before) != 0 || before.st_dev != root_dev) {
      const int saved_errno = errno == 0 ? EXDEV : errno;

      (void)close(child_fd);
      errno = saved_errno;
      return -1;
    }
    directory = fdopendir(child_fd);
    if (directory == NULL) {
      const int saved_errno = errno;

      (void)close(child_fd);
      errno = saved_errno;
      return -1;
    }
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
      if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0 &&
          remove_tree_entry_nofollow(child_fd, entry->d_name, root_dev) != 0) {
        const int saved_errno = errno;

        (void)closedir(directory);
        errno = saved_errno;
        return -1;
      }
    }
    if (errno != 0 || closedir(directory) != 0) {
      return -1;
    }
    if (unlinkat(parent_fd, name, AT_REMOVEDIR) != 0) {
      return -1;
    }
    return 0;
  }
  if (unlinkat(parent_fd, name, 0) != 0) {
    return -1;
  }
  return 0;
}

static int clear_workspace_children(int workspace_fd) {
  struct stat workspace_stat;
  DIR *directory;
  struct dirent *entry;
  int scan_fd;

  if (fstat(workspace_fd, &workspace_stat) != 0 || !S_ISDIR(workspace_stat.st_mode)) {
    return -1;
  }
  if (dup_directory_fd(workspace_fd, &scan_fd) != 0) {
    return -1;
  }
  directory = fdopendir(scan_fd);
  if (directory == NULL) {
    const int saved_errno = errno;

    (void)close(scan_fd);
    errno = saved_errno;
    return -1;
  }
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0 &&
        remove_tree_entry_nofollow(workspace_fd, entry->d_name, workspace_stat.st_dev) != 0) {
      const int saved_errno = errno;

      (void)closedir(directory);
      errno = saved_errno;
      return -1;
    }
  }
  if (errno != 0 || closedir(directory) != 0) {
    return -1;
  }
  return 0;
}

static int btrfs_create_snapshot(int workspace_fd, int project_fd, const char *name) {
  struct btrfs_ioctl_vol_args_v2 arguments = { 0 };

  if (!is_safe_component(name)) {
    errno = EINVAL;
    return -1;
  }
  arguments.fd = project_fd;
  memcpy(arguments.name, name, strlen(name) + 1U);
  return ioctl(workspace_fd, BTRFS_IOC_SNAP_CREATE_V2, &arguments);
}

static int btrfs_destroy_snapshot(int workspace_fd, const char *name) {
  struct btrfs_ioctl_vol_args_v2 arguments = { 0 };

  if (!is_safe_component(name)) {
    errno = EINVAL;
    return -1;
  }
  memcpy(arguments.name, name, strlen(name) + 1U);
  return ioctl(workspace_fd, BTRFS_IOC_SNAP_DESTROY_V2, &arguments);
}

static int btrfs_subvolume_fd(int file_descriptor) {
#ifdef BTRFS_IOC_GET_SUBVOL_INFO
  struct btrfs_ioctl_get_subvol_info_args information = { 0 };

  return ioctl(file_descriptor, BTRFS_IOC_GET_SUBVOL_INFO, &information);
#else
  (void)file_descriptor;
  errno = ENOTTY;
  return -1;
#endif
}

static int open_strategy_child(int workspace_fd, const char *name, int *child_fd_out) {
  enum open_result result =
      call_openat2(workspace_fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC, child_fd_out);

  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("workspace protocol: cannot open strategy child", name);
  }
  return 0;
}

static int validate_btrfs_child(int workspace_fd, const char *name, int *child_fd_out) {
  int child_fd = -1;

  if (open_strategy_child(workspace_fd, name, &child_fd) != 0) {
    return -1;
  }
  if (btrfs_subvolume_fd(child_fd) != 0) {
    const int saved_errno = errno;

    (void)close(child_fd);
    errno = saved_errno;
    return fail_errno("workspace protocol: strategy child is not a btrfs subvolume", name);
  }
  *child_fd_out = child_fd;
  return 0;
}

static bool btrfs_probe_fallback_errno(int error_number) {
  return error_number == EOPNOTSUPP || error_number == ENOTTY || error_number == EPERM ||
         error_number == EACCES || error_number == EXDEV || error_number == EROFS;
}

static int resolve_auto_strategy(int workspace_fd, int project_fd, const char *nonce,
                                 enum workspace_strategy *strategy_out) {
  char probe_name[NAME_MAX + 1U];
  const int name_length = snprintf(probe_name, sizeof(probe_name), ".ocsb-probe-%.24s-%ld", nonce,
                                   (long)getpid());

  if (name_length < 0 || (size_t)name_length >= sizeof(probe_name)) {
    errorf("workspace protocol: cannot format btrfs probe name");
    return -1;
  }
  if (btrfs_create_snapshot(workspace_fd, project_fd, probe_name) == 0) {
    if (btrfs_destroy_snapshot(workspace_fd, probe_name) != 0) {
      return fail_errno("workspace protocol: cannot remove btrfs probe", probe_name);
    }
    *strategy_out = WORKSPACE_STRATEGY_BTRFS;
    return 0;
  }
  if (btrfs_probe_fallback_errno(errno)) {
    *strategy_out = WORKSPACE_STRATEGY_OVERLAYFS;
    return 0;
  }
  return fail_errno("workspace protocol: btrfs strategy probe failed", NULL);
}

static char **environment_without_git(void) {
  size_t count = 0U;
  size_t index;
  char **clean_environment;

  while (environ[count] != NULL) {
    ++count;
  }
  clean_environment = calloc(count + 1U, sizeof(*clean_environment));
  if (clean_environment == NULL) {
    return NULL;
  }
  count = 0U;
  for (index = 0U; environ[index] != NULL; ++index) {
    if (strncmp(environ[index], "GIT_", 4U) != 0) {
      clean_environment[count++] = environ[index];
    }
  }
  return clean_environment;
}

static void close_extra_fds_for_git(void) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, 3U, UINT_MAX, 0U) == 0) {
    return;
  }
#endif
  {
    long maximum = sysconf(_SC_OPEN_MAX);
    long descriptor;

    if (maximum < 4L) {
      maximum = 65536L;
    }
    for (descriptor = 3L; descriptor < maximum; ++descriptor) {
      (void)close((int)descriptor);
    }
  }
}

static int run_git_command(int workspace_fd, const char *git_bin, char *const *arguments,
                           char **output_out) {
  int output_pipe[2] = { -1, -1 };
  pid_t child;
  int wait_status;
  char *output = NULL;
  size_t output_length = 0U;
  size_t output_capacity = 0U;
  bool output_too_large = false;

  if (output_out != NULL && pipe2(output_pipe, O_CLOEXEC) != 0) {
    return -1;
  }
  child = fork();
  if (child < 0) {
    const int saved_errno = errno;

    if (output_pipe[0] >= 0) {
      (void)close(output_pipe[0]);
      (void)close(output_pipe[1]);
    }
    errno = saved_errno;
    return -1;
  }
  if (child == 0) {
    char **clean_environment;

    if (output_out != NULL) {
      (void)close(output_pipe[0]);
      if (dup2(output_pipe[1], STDOUT_FILENO) < 0) {
        _exit(127);
      }
      (void)close(output_pipe[1]);
    }
    if (fchdir(workspace_fd) != 0) {
      _exit(127);
    }
    close_extra_fds_for_git();
    clean_environment = environment_without_git();
    if (clean_environment == NULL) {
      _exit(127);
    }
    execve(git_bin, arguments, clean_environment);
    _exit(127);
  }
  if (output_out != NULL) {
    char buffer[4096];
    ssize_t read_count;

    (void)close(output_pipe[1]);
    do {
      read_count = read(output_pipe[0], buffer, sizeof(buffer));
      if (read_count > 0) {
        const size_t amount = (size_t)read_count;

        if (output_length > 1024U * 1024U - amount) {
          output_too_large = true;
          continue;
        }
        if (output_length + amount + 1U > output_capacity) {
          size_t next_capacity = output_capacity == 0U ? 4096U : output_capacity;
          char *expanded;

          while (next_capacity < output_length + amount + 1U) {
            if (next_capacity > 1024U * 1024U / 2U) {
              next_capacity = 1024U * 1024U + 1U;
              break;
            }
            next_capacity *= 2U;
          }
          expanded = realloc(output, next_capacity);
          if (expanded == NULL) {
            output_too_large = true;
            continue;
          }
          output = expanded;
          output_capacity = next_capacity;
        }
        memcpy(output + output_length, buffer, amount);
        output_length += amount;
      }
    } while (read_count > 0 || (read_count < 0 && errno == EINTR));
    if (read_count < 0) {
      const int saved_errno = errno;

      (void)close(output_pipe[0]);
      (void)waitpid(child, &wait_status, 0);
      free(output);
      errno = saved_errno;
      return -1;
    }
    if (close(output_pipe[0]) != 0) {
      const int saved_errno = errno;

      (void)waitpid(child, &wait_status, 0);
      free(output);
      errno = saved_errno;
      return -1;
    }
  }
  while (waitpid(child, &wait_status, 0) < 0) {
    if (errno != EINTR) {
      free(output);
      return -1;
    }
  }
  if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0 || output_too_large) {
    free(output);
    errno = output_too_large ? EOVERFLOW : ECHILD;
    return -1;
  }
  if (output_out != NULL) {
    if (output == NULL) {
      output = strdup("");
      if (output == NULL) {
        return -1;
      }
    } else {
      output[output_length] = '\0';
    }
    *output_out = output;
  }
  return 0;
}

static bool directory_fds_match(int held_fd, int public_fd) {
  struct stat held_stat;
  struct stat public_stat;

  return fstat(held_fd, &held_stat) == 0 && fstat(public_fd, &public_stat) == 0 &&
         S_ISDIR(held_stat.st_mode) && S_ISDIR(public_stat.st_mode) &&
         held_stat.st_dev == public_stat.st_dev && held_stat.st_ino == public_stat.st_ino;
}

/* Git runs from the held workspace FD.  Existing public-path callers keep the
 * public revalidation, while inherited-root callers derive every component
 * from the held project descriptor and compare the resulting identities. */
static int revalidate_public_workspace_tree(const struct workspace_mutation_spec *spec,
                                             const struct workspace_tree *tree) {
  int project_fd = -1;
  int base_fd = -1;
  int workspace_fd = -1;
  int result = -1;

  if (tree->project_fd < 0 || tree->base_fd < 0 || tree->workspace_fd < 0 ||
      (tree->project_from_inherited_root
           ? dup_directory_fd(tree->project_fd, &project_fd)
           : open_absolute_directory(spec->project, &project_fd)) != 0 ||
      !directory_fds_match(tree->project_fd, project_fd) ||
      open_base_directory(project_fd, spec->base, false, &base_fd) != 0 ||
      !directory_fds_match(tree->base_fd, base_fd) ||
      open_directory_component(base_fd, spec->workspace, false, &workspace_fd) != 0 ||
      !directory_fds_match(tree->workspace_fd, workspace_fd)) {
    goto out;
  }
  result = 0;

out:
  if (workspace_fd >= 0) {
    (void)close(workspace_fd);
  }
  if (base_fd >= 0) {
    (void)close(base_fd);
  }
  if (project_fd >= 0) {
    (void)close(project_fd);
  }
  if (result != 0) {
    errorf("workspace protocol: public workspace identity mismatch");
  }
  return result;
}

static int run_revalidated_git(const struct workspace_mutation_spec *spec,
                                const struct workspace_tree *tree, const char *git_bin,
                                char *const *arguments, char **output_out) {
  int result;

  if (revalidate_public_workspace_tree(spec, tree) != 0) {
    return -1;
  }
  result = run_git_command(tree->workspace_fd, git_bin, arguments, output_out);
  if (revalidate_public_workspace_tree(spec, tree) != 0) {
    free(output_out == NULL ? NULL : *output_out);
    if (output_out != NULL) {
      *output_out = NULL;
    }
    return -1;
  }
  return result;
}

static int git_worktree_add(const struct workspace_mutation_spec *spec,
                             const struct workspace_tree *tree,
                             const char *git_bin) {
  char *arguments[7] = { (char *)git_bin, "worktree", "add", "--detach", "worktree", "HEAD", NULL };

  /* The child runs after fchdir(workspace_fd), so this relative path is bound
   * to the held workspace inode instead of a re-resolvable public pathname. */
  return run_revalidated_git(spec, tree, git_bin, arguments, NULL);
}

/* Rollback runs only against the held workspace FD after a failed mutation.
 * It intentionally avoids public-path revalidation, which may have failed. */
static int git_worktree_remove_relative_held(int workspace_fd, const char *git_bin) {
  char *remove_arguments[6] = { (char *)git_bin, "worktree", "remove", "--force", "worktree", NULL };
  char *prune_arguments[4] = { (char *)git_bin, "worktree", "prune", NULL };

  if (run_git_command(workspace_fd, git_bin, remove_arguments, NULL) != 0) {
    return -1;
  }
  return run_git_command(workspace_fd, git_bin, prune_arguments, NULL);
}

static int git_worktree_remove_relative(const struct workspace_mutation_spec *spec,
                                         const struct workspace_tree *tree, const char *git_bin) {
  char *remove_arguments[6] = { (char *)git_bin, "worktree", "remove", "--force", "worktree", NULL };
  char *prune_arguments[4] = { (char *)git_bin, "worktree", "prune", NULL };

  if (run_revalidated_git(spec, tree, git_bin, remove_arguments, NULL) != 0) {
    return -1;
  }
  return run_revalidated_git(spec, tree, git_bin, prune_arguments, NULL);
}

static int git_worktree_is_registered(const struct workspace_mutation_spec *spec,
                                       const struct workspace_tree *tree, const char *git_bin) {
  char *arguments[5] = { (char *)git_bin, "worktree", "list", "--porcelain", NULL };
  char *output = NULL;
  char *cursor;
  const char *expected_prefix = "worktree ";
  struct stat expected_stat;
  int expected_fd = -1;
  int result = -1;

  if (open_strategy_child(tree->workspace_fd, "worktree", &expected_fd) != 0 ||
      fstat(expected_fd, &expected_stat) != 0 ||
      run_revalidated_git(spec, tree, git_bin, arguments, &output) != 0) {
    if (expected_fd >= 0) {
      (void)close(expected_fd);
    }
    free(output);
    return -1;
  }
  if (close(expected_fd) != 0) {
    free(output);
    return -1;
  }
  cursor = output;
  while (*cursor != '\0') {
    char *line_end = strchr(cursor, '\n');

    if (line_end != NULL) {
      *line_end = '\0';
    }
    if (strncmp(cursor, expected_prefix, strlen(expected_prefix)) == 0) {
      const char *listed_path = cursor + strlen(expected_prefix);

      if (tree->project_from_inherited_root) {
        const int expected_length =
            snprintf(NULL, 0, "%s/%s/%s/worktree", spec->project, spec->base, spec->workspace);
        char *expected_path;

        if (expected_length < 0 || (uintmax_t)expected_length > (uintmax_t)(SIZE_MAX - 1U)) {
          free(output);
          errno = EOVERFLOW;
          return -1;
        }
        expected_path = malloc((size_t)expected_length + 1U);
        if (expected_path == NULL) {
          free(output);
          return -1;
        }
        if (snprintf(expected_path, (size_t)expected_length + 1U, "%s/%s/%s/worktree",
                     spec->project, spec->base, spec->workspace) == expected_length &&
            strcmp(listed_path, expected_path) == 0) {
          result = 0;
        }
        free(expected_path);
      } else {
        int listed_fd = -1;
        struct stat listed_stat;

        if (open_absolute_directory(listed_path, &listed_fd) == 0 &&
            fstat(listed_fd, &listed_stat) == 0 && listed_stat.st_dev == expected_stat.st_dev &&
            listed_stat.st_ino == expected_stat.st_ino) {
          result = 0;
        }
        if (listed_fd >= 0) {
          (void)close(listed_fd);
        }
      }
      if (result == 0) {
        break;
      }
    }
    if (line_end == NULL) {
      break;
    }
    cursor = line_end + 1;
  }
  free(output);
  if (result != 0) {
    errorf("workspace protocol: git worktree metadata does not match the workspace");
  }
  return result;
}

static int validate_receipt_parent_fd(int parent_fd, const char *path) {
  struct stat status;

  if (fstat(parent_fd, &status) != 0) {
    return fail_errno("workspace receipt: cannot stat parent", path);
  }
  if (!S_ISDIR(status.st_mode) || status.st_uid != getuid() || (status.st_mode & 0777U) != 0700U) {
    errorf("workspace receipt: unsafe parent: %s must be a current-UID mode 0700 directory", path);
    return -1;
  }
  return 0;
}

static int open_workspace_receipt_parent(const struct configuration *configuration,
                                          int *parent_fd_out) {
  int parent_fd = -1;

  if (open_workspace_directory(configuration, INHERITED_ROOT_STATE_BASE,
                               configuration->workspace_receipt_parent,
                               configuration->workspace_receipt_parent, &parent_fd,
                               NULL) != 0 ||
      validate_receipt_parent_fd(parent_fd, configuration->workspace_receipt_parent) != 0) {
    if (parent_fd >= 0) {
      (void)close(parent_fd);
    }
    return -1;
  }
  *parent_fd_out = parent_fd;
  return 0;
}

static int validate_receipt_file_stat(const struct stat *status, const char *path) {
  if (!S_ISREG(status->st_mode) || status->st_uid != getuid() ||
      (status->st_mode & 0777U) != 0600U) {
    errorf("workspace receipt: unsafe file: %s must be a current-UID mode 0600 regular file", path);
    return -1;
  }
  return 0;
}

static int validate_existing_receipt_target(int parent_fd, const struct configuration *configuration) {
  struct stat status;

  if (fstatat(parent_fd, configuration->workspace_receipt_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) {
      return 0;
    }
    return fail_errno("workspace receipt: cannot inspect existing file",
                      configuration->workspace_receipt_path);
  }
  return validate_receipt_file_stat(&status, configuration->workspace_receipt_path);
}

static int open_receipt_file(int parent_fd, const struct configuration *configuration, int *file_fd_out,
                             struct stat *file_stat_out) {
  int file_fd = -1;
  struct stat status;
  enum open_result result = call_openat2(parent_fd, configuration->workspace_receipt_name,
                                          O_RDWR | O_CLOEXEC, &file_fd);

  if (result == OPEN_RESULT_UNSUPPORTED) {
    return fail_openat2_unsupported();
  }
  if (result != OPEN_RESULT_OK) {
    return fail_errno("workspace receipt: cannot open", configuration->workspace_receipt_path);
  }
  if (fstat(file_fd, &status) != 0 ||
      validate_receipt_file_stat(&status, configuration->workspace_receipt_path) != 0) {
    const int saved_errno = errno;

    (void)close(file_fd);
    errno = saved_errno;
    return -1;
  }
  *file_fd_out = file_fd;
  *file_stat_out = status;
  return 0;
}

static int read_receipt_line(int file_fd, const struct stat *file_stat, char **line_out) {
  size_t offset = 0U;
  size_t expected_size;
  char *line;

  if (file_stat->st_size <= 0 || (uintmax_t)file_stat->st_size > 65536U) {
    errno = EINVAL;
    return -1;
  }
  expected_size = (size_t)file_stat->st_size;
  line = malloc(expected_size + 1U);
  if (line == NULL) {
    return -1;
  }
  while (offset < expected_size) {
    const ssize_t read_count = read(file_fd, line + offset, expected_size - offset);

    if (read_count < 0) {
      if (errno == EINTR) {
        continue;
      }
      free(line);
      return -1;
    }
    if (read_count == 0) {
      free(line);
      errno = EIO;
      return -1;
    }
    offset += (size_t)read_count;
  }
  line[expected_size] = '\0';
  {
    struct stat after_read;

    if (fstat(file_fd, &after_read) != 0 || after_read.st_dev != file_stat->st_dev ||
        after_read.st_ino != file_stat->st_ino || after_read.st_size != file_stat->st_size) {
      free(line);
      errno = EAGAIN;
      return -1;
    }
  }
  if (line[expected_size - 1U] != '\n' || strchr(line, '\0') != line + expected_size) {
    free(line);
    errno = EINVAL;
    return -1;
  }
  {
    size_t index;

    for (index = 0U; index + 1U < expected_size; ++index) {
      if (line[index] == '\n' || line[index] == '\r') {
        free(line);
        errno = EINVAL;
        return -1;
      }
    }
  }
  *line_out = line;
  return 0;
}

static int parse_workspace_receipt_line(struct workspace_receipt_data *receipt) {
  char *cursor;
  size_t index;

  receipt->fields_storage = strdup(receipt->line);
  if (receipt->fields_storage == NULL) {
    return -1;
  }
  cursor = receipt->fields_storage;
  {
    const size_t length = strlen(cursor);

    if (length == 0U || cursor[length - 1U] != '\n') {
      return -1;
    }
    cursor[length - 1U] = '\0';
  }
  for (index = 0U; index < 16U; ++index) {
    char *tab = strchr(cursor, '\t');

    if (tab == NULL) {
      return -1;
    }
    *tab = '\0';
    receipt->fields[index] = cursor;
    cursor = tab + 1;
  }
  if (strchr(cursor, '\t') != NULL) {
    return -1;
  }
  receipt->fields[16] = cursor;
  if (strcmp(receipt->fields[0], "v1") != 0 || !is_hex_nonce(receipt->fields[1]) ||
      validate_absolute_path(receipt->fields[2]) != 0 ||
      validate_base_relative_path(receipt->fields[3]) != 0 ||
      !is_safe_component(receipt->fields[4]) ||
      parse_dev(receipt->fields[5], &receipt->project_dev) != 0 ||
      parse_ino(receipt->fields[6], &receipt->project_ino) != 0 ||
      parse_dev(receipt->fields[7], &receipt->base_dev) != 0 ||
      parse_ino(receipt->fields[8], &receipt->base_ino) != 0 ||
      parse_dev(receipt->fields[9], &receipt->workspace_dev) != 0 ||
      parse_ino(receipt->fields[10], &receipt->workspace_ino) != 0 ||
      parse_workspace_strategy(receipt->fields[11], false, false, &receipt->strategy) != 0 ||
      parse_workspace_backend(receipt->fields[12], &receipt->backend) != 0 ||
      parse_dev(receipt->fields[14], &receipt->child_dev) != 0 ||
      parse_ino(receipt->fields[15], &receipt->child_ino) != 0) {
    return -1;
  }
  if (receipt->project_dev == 0 || receipt->project_ino == 0 || receipt->base_dev == 0 ||
      receipt->base_ino == 0 || receipt->workspace_dev == 0 || receipt->workspace_ino == 0) {
    return -1;
  }
  if ((receipt->strategy == WORKSPACE_STRATEGY_DIRECT ||
       receipt->strategy == WORKSPACE_STRATEGY_OVERLAYFS) &&
      (strcmp(receipt->fields[13], "none") != 0 || receipt->child_dev != 0 ||
       receipt->child_ino != 0 || strcmp(receipt->fields[16], "none") != 0)) {
    return -1;
  }
  if (receipt->strategy == WORKSPACE_STRATEGY_BTRFS &&
      (strcmp(receipt->fields[13], "snapshot") != 0 || receipt->child_dev == 0 ||
       receipt->child_ino == 0 || strcmp(receipt->fields[16], "btrfs-subvolume") != 0)) {
    return -1;
  }
  if (receipt->strategy == WORKSPACE_STRATEGY_GIT_WORKTREE &&
      (strcmp(receipt->fields[13], "worktree") != 0 || receipt->child_dev == 0 ||
       receipt->child_ino == 0 || strcmp(receipt->fields[16], "git-worktree") != 0)) {
    return -1;
  }
  return 0;
}

static void free_workspace_receipt(struct workspace_receipt_data *receipt) {
  if (receipt->receipt_fd >= 0) {
    (void)close(receipt->receipt_fd);
  }
  if (receipt->parent_fd >= 0) {
    (void)close(receipt->parent_fd);
  }
  free(receipt->line);
  free(receipt->fields_storage);
  *receipt = (struct workspace_receipt_data){ .parent_fd = -1, .receipt_fd = -1 };
}

static int load_workspace_receipt(const struct configuration *configuration,
                                   struct workspace_receipt_data *receipt) {
  *receipt = (struct workspace_receipt_data){ .parent_fd = -1, .receipt_fd = -1 };
  if (open_workspace_receipt_parent(configuration, &receipt->parent_fd) != 0 ||
      open_receipt_file(receipt->parent_fd, configuration, &receipt->receipt_fd,
                        &receipt->file_stat) != 0 ||
      read_receipt_line(receipt->receipt_fd, &receipt->file_stat, &receipt->line) != 0) {
    const int saved_errno = errno;

    free_workspace_receipt(receipt);
    errno = saved_errno;
    return -1;
  }
  if (parse_workspace_receipt_line(receipt) != 0) {
    const int saved_errno = errno == 0 ? EINVAL : errno;

    free_workspace_receipt(receipt);
    errno = saved_errno;
    errorf("workspace receipt: malformed receipt");
    return -1;
  }
  if (strcmp(receipt->fields[1], configuration->workspace_nonce) != 0 ||
      strcmp(receipt->fields[2], configuration->workspace_project) != 0 ||
      strcmp(receipt->fields[3], configuration->workspace_base) != 0 ||
      strcmp(receipt->fields[4], configuration->workspace_name) != 0 ||
      receipt->backend != configuration->backend) {
    errorf("workspace receipt: nonce, path, or backend does not match final invocation");
    return 1;
  }
  return 0;
}

static int write_workspace_receipt(const struct configuration *configuration, const char *line) {
  int parent_fd = -1;
  int temporary_fd = -1;
  char temporary_name[NAME_MAX + 1U] = { 0 };
  unsigned int attempt;
  int result = -1;

  if (open_workspace_receipt_parent(configuration, &parent_fd) != 0 ||
      validate_existing_receipt_target(parent_fd, configuration) != 0) {
    goto out;
  }
  for (attempt = 0U; attempt < 100U; ++attempt) {
    const int name_length = snprintf(temporary_name, sizeof(temporary_name), ".receipt-%ld-%u",
                                     (long)getpid(), attempt);

    if (name_length < 0 || (size_t)name_length >= sizeof(temporary_name)) {
      errno = EOVERFLOW;
      goto out;
    }
    temporary_fd = openat(parent_fd, temporary_name,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (temporary_fd >= 0) {
      break;
    }
    if (errno != EEXIST) {
      goto out;
    }
  }
  if (temporary_fd < 0 || fchmod(temporary_fd, 0600) != 0 || write_all(temporary_fd, line) != 0 ||
      fsync(temporary_fd) != 0 || close(temporary_fd) != 0) {
    temporary_fd = -1;
    goto out;
  }
  temporary_fd = -1;
  if (validate_existing_receipt_target(parent_fd, configuration) != 0 ||
      renameat(parent_fd, temporary_name, parent_fd, configuration->workspace_receipt_name) != 0 ||
      fsync(parent_fd) != 0) {
    goto out;
  }
  result = 0;

out:
  {
    const int saved_errno = errno;

    if (temporary_fd >= 0) {
      (void)close(temporary_fd);
    }
    if (parent_fd >= 0 && temporary_name[0] != '\0') {
      (void)unlinkat(parent_fd, temporary_name, 0);
    }
    if (parent_fd >= 0) {
      (void)close(parent_fd);
    }
    errno = saved_errno;
  }
  if (result != 0) {
    return fail_errno("workspace receipt: cannot publish", configuration->workspace_receipt_path);
  }
  return 0;
}

static int retained_receipt_name(char name[NAME_MAX + 1U], const char *nonce,
                                 const char *kind, unsigned int slot) {
  const int length = snprintf(name, NAME_MAX + 1U, ".workspace-receipt-%s.%s.%02u", nonce,
                              kind, slot);

  if (length < 0 || length > NAME_MAX) {
    errno = EOVERFLOW;
    return -1;
  }
  return 0;
}

static int fail_retained_receipt_slot_exhaustion(const char *kind) {
  errno = EEXIST;
  errorf("workspace receipt: retained slot exhaustion: no available %s slot", kind);
  return -1;
}

static int select_retained_receipt_spent_name(int parent_fd, const char *nonce,
                                               char name[NAME_MAX + 1U]) {
  unsigned int slot;

  for (slot = 0U; slot < 100U; ++slot) {
    struct stat status;

    if (retained_receipt_name(name, nonce, "spent", slot) != 0) {
      return -1;
    }
    if (fstatat(parent_fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0) {
      continue;
    }
    if (errno == ENOENT) {
      return 0;
    }
    return -1;
  }
  return fail_retained_receipt_slot_exhaustion("spent");
}

static int create_retained_receipt_guard(int parent_fd, const char *nonce,
                                          char name[NAME_MAX + 1U], int *guard_fd_out,
                                          struct stat *guard_stat_out) {
  unsigned int slot;

  for (slot = 0U; slot < 100U; ++slot) {
    int guard_fd;

    if (retained_receipt_name(name, nonce, "guard", slot) != 0) {
      return -1;
    }
    guard_fd = openat(parent_fd, name,
                      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (guard_fd < 0) {
      if (errno == EEXIST) {
        continue;
      }
      return -1;
    }
    *guard_fd_out = guard_fd;
    if (fchmod(guard_fd, 0600) != 0 || fstat(guard_fd, guard_stat_out) != 0 ||
        validate_receipt_file_stat(guard_stat_out, name) != 0) {
      return -1;
    }
    if (guard_stat_out->st_size != 0) {
      errno = EIO;
      return -1;
    }
    return 0;
  }
  return fail_retained_receipt_slot_exhaustion("guard");
}

static int exchange_receipt_names(int parent_fd, const char *left, const char *right) {
#ifdef SYS_renameat2
  return (int)syscall(SYS_renameat2, parent_fd, left, parent_fd, right, RENAME_EXCHANGE);
#else
  (void)parent_fd;
  (void)left;
  (void)right;
  errno = ENOSYS;
  return -1;
#endif
}

static int move_receipt_name_noreplace(int parent_fd, const char *source,
                                       const char *destination) {
#ifdef SYS_renameat2
  return (int)syscall(SYS_renameat2, parent_fd, source, parent_fd, destination,
                      RENAME_NOREPLACE);
#else
  (void)parent_fd;
  (void)source;
  (void)destination;
  errno = ENOSYS;
  return -1;
#endif
}

static bool same_file_identity(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static int validate_held_receipt_fd(const struct configuration *configuration,
                                    const struct workspace_receipt_data *receipt) {
  struct stat held_stat;

  if (receipt->receipt_fd < 0 || fstat(receipt->receipt_fd, &held_stat) != 0) {
    return fail_errno("workspace receipt: cannot stat held receipt",
                      configuration->workspace_receipt_path);
  }
  if (validate_receipt_file_stat(&held_stat, configuration->workspace_receipt_path) != 0) {
    return -1;
  }
  if (!same_file_identity(&held_stat, &receipt->file_stat)) {
    errno = EAGAIN;
    errorf("workspace receipt: held receipt identity changed before consumption");
    return -1;
  }
  return 0;
}

static int validate_moved_guard(int parent_fd, const char *spent_name, int guard_fd,
                                const struct stat *created_guard_stat) {
  struct stat held_guard_stat;
  struct stat named_guard_stat;

  if (fstat(guard_fd, &held_guard_stat) != 0 ||
      fstatat(parent_fd, spent_name, &named_guard_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    return -1;
  }
  if (validate_receipt_file_stat(&held_guard_stat, spent_name) != 0 ||
      validate_receipt_file_stat(&named_guard_stat, spent_name) != 0) {
    return -1;
  }
  if (!same_file_identity(&held_guard_stat, created_guard_stat) ||
      !same_file_identity(&named_guard_stat, &held_guard_stat) || held_guard_stat.st_size != 0 ||
      named_guard_stat.st_size != 0) {
    errno = EAGAIN;
    errorf("workspace receipt: moved guard identity changed during consumption");
    return -1;
  }
  return 0;
}

static int pread_loaded_receipt_line(const struct configuration *configuration,
                                     const struct workspace_receipt_data *receipt) {
  const size_t expected_size = strlen(receipt->line);
  size_t offset = 0U;
  char *loaded_line;
  struct stat before_read;
  struct stat after_read;

  if (fstat(receipt->receipt_fd, &before_read) != 0 ||
      validate_receipt_file_stat(&before_read, configuration->workspace_receipt_path) != 0) {
    return -1;
  }
  if (!same_file_identity(&before_read, &receipt->file_stat) ||
      before_read.st_size < 0 || (uintmax_t)before_read.st_size != (uintmax_t)expected_size) {
    errno = EAGAIN;
    errorf("workspace receipt: held receipt bytes changed before retirement");
    return -1;
  }
  loaded_line = malloc(expected_size == 0U ? 1U : expected_size);
  if (loaded_line == NULL) {
    return -1;
  }
  while (offset < expected_size) {
    const ssize_t read_count = pread(receipt->receipt_fd, loaded_line + offset,
                                     expected_size - offset, (off_t)offset);

    if (read_count < 0) {
      if (errno == EINTR) {
        continue;
      }
      free(loaded_line);
      return -1;
    }
    if (read_count == 0) {
      free(loaded_line);
      errno = EIO;
      return -1;
    }
    offset += (size_t)read_count;
  }
  if (fstat(receipt->receipt_fd, &after_read) != 0 ||
      !same_file_identity(&after_read, &before_read) ||
      after_read.st_size != before_read.st_size ||
      memcmp(loaded_line, receipt->line, expected_size) != 0) {
    free(loaded_line);
    errno = EAGAIN;
    errorf("workspace receipt: held receipt bytes changed before retirement");
    return -1;
  }
  free(loaded_line);
  return 0;
}

static int validate_retained_receipt_name(const struct configuration *configuration,
                                          const struct workspace_receipt_data *receipt,
                                          const char *guard_name) {
  struct stat named_receipt_stat;

  if (fstatat(receipt->parent_fd, guard_name, &named_receipt_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    return -1;
  }
  if (validate_receipt_file_stat(&named_receipt_stat, guard_name) != 0) {
    return -1;
  }
  if (!same_file_identity(&named_receipt_stat, &receipt->file_stat)) {
    errno = EAGAIN;
    errorf("workspace receipt: retained receipt identity changed during consumption");
    return -1;
  }
  return pread_loaded_receipt_line(configuration, receipt);
}

static int consume_workspace_receipt(struct configuration *configuration,
                                     struct workspace_receipt_data *receipt) {
  char guard_name[NAME_MAX + 1U] = { 0 };
  char spent_name[NAME_MAX + 1U] = { 0 };
  struct stat created_guard_stat;
  int guard_fd = -1;
  int result = -1;

  if (receipt->consume_attempted) {
    errno = EALREADY;
    return fail_errno("workspace receipt: cannot consume exact receipt",
                      configuration->workspace_receipt_path);
  }
  receipt->consume_attempted = true;
  if (validate_receipt_parent_fd(receipt->parent_fd, configuration->workspace_receipt_parent) != 0 ||
      validate_held_receipt_fd(configuration, receipt) != 0 ||
      select_retained_receipt_spent_name(receipt->parent_fd, configuration->workspace_nonce,
                                         spent_name) != 0 ||
      create_retained_receipt_guard(receipt->parent_fd, configuration->workspace_nonce,
                                    guard_name, &guard_fd, &created_guard_stat) != 0) {
    goto out;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_receipt_consume_hook(configuration) != 0) {
    goto out;
  }
#endif
  if (exchange_receipt_names(receipt->parent_fd, configuration->workspace_receipt_name,
                             guard_name) != 0) {
    goto out;
  }
  if (move_receipt_name_noreplace(receipt->parent_fd, configuration->workspace_receipt_name,
                                  spent_name) != 0 ||
      validate_moved_guard(receipt->parent_fd, spent_name, guard_fd,
                           &created_guard_stat) != 0) {
    goto out;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_moved_guard_validation_hook(configuration) != 0) {
    goto out;
  }
#endif
  if (validate_retained_receipt_name(configuration, receipt, guard_name) != 0) {
    goto out;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_quarantined_receipt_validation_hook(configuration) != 0) {
    goto out;
  }
#endif
  if (ftruncate(receipt->receipt_fd, 0) != 0 || fsync(receipt->receipt_fd) != 0 ||
      fsync(receipt->parent_fd) != 0) {
    goto out;
  }
  result = 0;

out:
  {
    int saved_errno = errno;

    if (guard_fd >= 0 && close(guard_fd) != 0 && result == 0) {
      saved_errno = errno;
      result = -1;
    }
    errno = saved_errno;
  }
  if (result != 0) {
    return fail_errno("workspace receipt: cannot consume exact receipt",
                      configuration->workspace_receipt_path);
  }
  return 0;
}

static void discard_nonce_matching_workspace_receipt(
    struct configuration *configuration, struct workspace_receipt_data *receipt) {
  if (receipt->fields_storage != NULL &&
      strcmp(receipt->fields[1], configuration->workspace_nonce) == 0 &&
      !receipt->consume_attempted) {
    (void)consume_workspace_receipt(configuration, receipt);
  }
}

static const char *strategy_child_name(enum workspace_strategy strategy) {
  if (strategy == WORKSPACE_STRATEGY_BTRFS) {
    return "snapshot";
  }
  if (strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    return "worktree";
  }
  return NULL;
}

static int validate_existing_workspace_strategy(const struct workspace_mutation_spec *spec,
                                                const struct workspace_tree *tree,
                                                const char *git_bin) {
  int child_fd = -1;
  int result = 0;
  const char *child_name = strategy_child_name(spec->cleanup_strategy);

  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_DIRECT ||
      spec->cleanup_strategy == WORKSPACE_STRATEGY_OVERLAYFS) {
    return 0;
  }
  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_NONE || child_name == NULL) {
    errorf("workspace protocol: continue has no existing strategy to validate");
    return -1;
  }
  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_BTRFS) {
    result = validate_btrfs_child(tree->workspace_fd, child_name, &child_fd);
  } else {
    result = open_strategy_child(tree->workspace_fd, child_name, &child_fd);
  }
  if (child_fd >= 0 && close(child_fd) != 0 && result == 0) {
    result = -1;
  }
  if (result != 0) {
    return result;
  }
  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    return git_worktree_is_registered(spec, tree, git_bin);
  }
  return 0;
}

static int remove_existing_workspace_strategy(const struct workspace_mutation_spec *spec,
                                              const struct workspace_tree *tree,
                                              const char *git_bin) {
  const char *child_name = strategy_child_name(spec->cleanup_strategy);
  int child_fd = -1;

  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_NONE ||
      spec->cleanup_strategy == WORKSPACE_STRATEGY_DIRECT ||
      spec->cleanup_strategy == WORKSPACE_STRATEGY_OVERLAYFS) {
    return 0;
  }
  if (child_name == NULL) {
    errorf("workspace protocol: invalid cleanup strategy");
    return -1;
  }
  if (spec->cleanup_strategy == WORKSPACE_STRATEGY_BTRFS) {
    if (validate_btrfs_child(tree->workspace_fd, child_name, &child_fd) != 0) {
      return -1;
    }
    if (close(child_fd) != 0) {
      return -1;
    }
    if (btrfs_destroy_snapshot(tree->workspace_fd, child_name) != 0) {
      return fail_errno("workspace protocol: cannot destroy btrfs strategy child", child_name);
    }
  } else if (spec->cleanup_strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    if (open_strategy_child(tree->workspace_fd, child_name, &child_fd) != 0) {
      return -1;
    }
    if (close(child_fd) != 0 || git_worktree_is_registered(spec, tree, git_bin) != 0 ||
        git_worktree_remove_relative(spec, tree, git_bin) != 0) {
      return -1;
    }
  }
  return 0;
}

static int create_workspace_strategy(const struct workspace_mutation_spec *spec,
                                     const struct workspace_tree *tree, const char *git_bin,
                                     bool *created_out) {
  const char *child_name = strategy_child_name(spec->requested_strategy);
  int child_fd = -1;

  *created_out = false;
  if (spec->requested_strategy == WORKSPACE_STRATEGY_DIRECT ||
      spec->requested_strategy == WORKSPACE_STRATEGY_OVERLAYFS) {
    return 0;
  }
  if (spec->requested_strategy == WORKSPACE_STRATEGY_BTRFS) {
    if (btrfs_create_snapshot(tree->workspace_fd, tree->project_fd, "snapshot") != 0) {
      return fail_errno("workspace protocol: btrfs strategy unavailable", "snapshot");
    }
    *created_out = true;
    if (validate_btrfs_child(tree->workspace_fd, child_name, &child_fd) != 0) {
      return -1;
    }
    if (close(child_fd) != 0) {
      return -1;
    }
    return 0;
  }
  if (spec->requested_strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    /* A failing git add can still have created a partial worktree. */
    *created_out = true;
    if (git_worktree_add(spec, tree, git_bin) != 0) {
      return fail_errno("workspace protocol: cannot create git worktree", NULL);
    }
    if (open_strategy_child(tree->workspace_fd, child_name, &child_fd) != 0 ||
        (child_fd >= 0 && close(child_fd) != 0) ||
        git_worktree_is_registered(spec, tree, git_bin) != 0) {
      if (child_fd >= 0) {
        (void)close(child_fd);
      }
      return -1;
    }
    return 0;
  }
  errorf("workspace protocol: unresolved workspace strategy");
  return -1;
}

static void rollback_new_workspace_strategy(const struct workspace_mutation_spec *spec,
                                            const struct workspace_tree *tree, const char *git_bin,
                                            bool strategy_created) {
  if (!strategy_created) {
    return;
  }
  if (spec->requested_strategy == WORKSPACE_STRATEGY_BTRFS) {
    (void)btrfs_destroy_snapshot(tree->workspace_fd, "snapshot");
  } else if (spec->requested_strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    (void)git_worktree_remove_relative_held(tree->workspace_fd, git_bin);
  }
}

static int build_workspace_receipt_line(const struct workspace_mutation_spec *spec,
                                        const struct workspace_tree *tree, char **line_out) {
  struct stat project_stat;
  struct stat base_stat;
  struct stat workspace_stat;
  struct stat child_stat = { 0 };
  const char *child_name = strategy_child_name(spec->requested_strategy);
  const char *child_type = "none";
  int child_fd = -1;
  int required;
  char *line;

  if (fstat(tree->project_fd, &project_stat) != 0 || fstat(tree->base_fd, &base_stat) != 0 ||
      fstat(tree->workspace_fd, &workspace_stat) != 0 || !S_ISDIR(project_stat.st_mode) ||
      !S_ISDIR(base_stat.st_mode) || !S_ISDIR(workspace_stat.st_mode)) {
    return -1;
  }
  if (child_name != NULL) {
    if ((spec->requested_strategy == WORKSPACE_STRATEGY_BTRFS &&
         validate_btrfs_child(tree->workspace_fd, child_name, &child_fd) != 0) ||
        (spec->requested_strategy == WORKSPACE_STRATEGY_GIT_WORKTREE &&
         open_strategy_child(tree->workspace_fd, child_name, &child_fd) != 0) ||
        fstat(child_fd, &child_stat) != 0 || !S_ISDIR(child_stat.st_mode)) {
      const int saved_errno = errno;

      if (child_fd >= 0) {
        (void)close(child_fd);
      }
      errno = saved_errno;
      return -1;
    }
    if (close(child_fd) != 0) {
      return -1;
    }
    child_type = spec->requested_strategy == WORKSPACE_STRATEGY_BTRFS ? "btrfs-subvolume"
                                                                        : "git-worktree";
  } else {
    child_name = "none";
  }
  required = snprintf(
      NULL, 0,
      "v1\t%s\t%s\t%s\t%s\t%" PRIuMAX "\t%" PRIuMAX "\t%" PRIuMAX "\t%" PRIuMAX
      "\t%" PRIuMAX "\t%" PRIuMAX "\t%s\t%s\t%s\t%" PRIuMAX "\t%" PRIuMAX "\t%s\n",
      spec->nonce, spec->project, spec->base, spec->workspace, (uintmax_t)project_stat.st_dev,
      (uintmax_t)project_stat.st_ino, (uintmax_t)base_stat.st_dev, (uintmax_t)base_stat.st_ino,
      (uintmax_t)workspace_stat.st_dev, (uintmax_t)workspace_stat.st_ino,
      workspace_strategy_name(spec->requested_strategy), workspace_backend_name(spec->backend),
      child_name, (uintmax_t)child_stat.st_dev, (uintmax_t)child_stat.st_ino, child_type);
  if (required < 0 || (uintmax_t)required > (uintmax_t)(SIZE_MAX - 1U)) {
    errno = EOVERFLOW;
    return -1;
  }
  line = malloc((size_t)required + 1U);
  if (line == NULL ||
      snprintf(line, (size_t)required + 1U,
               "v1\t%s\t%s\t%s\t%s\t%" PRIuMAX "\t%" PRIuMAX "\t%" PRIuMAX "\t%" PRIuMAX
               "\t%" PRIuMAX "\t%" PRIuMAX "\t%s\t%s\t%s\t%" PRIuMAX "\t%" PRIuMAX "\t%s\n",
               spec->nonce, spec->project, spec->base, spec->workspace,
               (uintmax_t)project_stat.st_dev, (uintmax_t)project_stat.st_ino,
               (uintmax_t)base_stat.st_dev, (uintmax_t)base_stat.st_ino,
               (uintmax_t)workspace_stat.st_dev, (uintmax_t)workspace_stat.st_ino,
               workspace_strategy_name(spec->requested_strategy), workspace_backend_name(spec->backend),
               child_name, (uintmax_t)child_stat.st_dev, (uintmax_t)child_stat.st_ino,
               child_type) != required) {
    free(line);
    return -1;
  }
  *line_out = line;
  return 0;
}

static int execute_workspace_mutation(struct configuration *configuration) {
  struct workspace_mutation_spec *spec = &configuration->mutation_spec;
  struct workspace_tree tree = { .project_fd = -1, .base_fd = -1, .workspace_fd = -1 };
  enum workspace_strategy resolved_strategy;
  bool strategy_created = false;
  char *receipt_line = NULL;
  int result = -1;

  if (strcmp(configuration->workspace_receipt_parent, spec->state_dir) != 0) {
    errorf("workspace protocol: receipt parent must equal the mutation state directory");
    return -1;
  }
  if (spec->action == WORKSPACE_ACTION_CREATE && spec->cleanup_strategy != WORKSPACE_STRATEGY_NONE) {
    errorf("workspace protocol: create requires cleanup strategy none");
    return -1;
  }
  if (spec->action == WORKSPACE_ACTION_CONTINUE) {
    if (spec->requested_strategy == WORKSPACE_STRATEGY_AUTO) {
      if (spec->cleanup_strategy != WORKSPACE_STRATEGY_BTRFS &&
          spec->cleanup_strategy != WORKSPACE_STRATEGY_OVERLAYFS) {
        errorf("workspace protocol: continue auto accepts only btrfs or overlayfs");
        return -1;
      }
    } else if (spec->requested_strategy != spec->cleanup_strategy ||
               spec->cleanup_strategy == WORKSPACE_STRATEGY_NONE) {
      errorf("workspace protocol: continue strategy does not match existing strategy");
      return -1;
    }
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_inherited_mutation_open_hook(configuration) != 0) {
    goto out;
  }
#endif
  if (open_workspace_tree(configuration, spec, &tree) != 0) {
    goto out;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_mutation_hook(configuration) != 0) {
    goto out;
  }
#endif
  if (spec->action == WORKSPACE_ACTION_CONTINUE) {
    resolved_strategy = spec->cleanup_strategy;
    if (validate_existing_workspace_strategy(spec, &tree, configuration->git_bin) != 0) {
      goto out;
    }
  } else {
    if (!tree.workspace_created) {
      if (remove_existing_workspace_strategy(spec, &tree, configuration->git_bin) != 0 ||
          clear_workspace_children(tree.workspace_fd) != 0) {
        (void)fail_errno("workspace protocol: cannot clear existing workspace", spec->workspace);
        goto out;
      }
    } else if (spec->action == WORKSPACE_ACTION_OVERWRITE &&
               spec->cleanup_strategy != WORKSPACE_STRATEGY_NONE) {
      errorf("workspace protocol: overwrite cleanup strategy requires an existing workspace");
      goto out;
    }
    if (spec->requested_strategy == WORKSPACE_STRATEGY_AUTO) {
      if (resolve_auto_strategy(tree.workspace_fd, tree.project_fd, spec->nonce, &resolved_strategy) != 0) {
        goto out;
      }
    } else {
      resolved_strategy = spec->requested_strategy;
    }
    if (resolved_strategy == WORKSPACE_STRATEGY_OVERLAYFS &&
        spec->backend != BACKEND_BUBBLEWRAP) {
      errorf("workspace protocol: backend '%s' does not support overlayfs workspaces",
             workspace_backend_name(spec->backend));
      goto out;
    }
    spec->requested_strategy = resolved_strategy;
    if (create_workspace_strategy(spec, &tree, configuration->git_bin, &strategy_created) != 0) {
      goto out;
    }
  }
  spec->requested_strategy = resolved_strategy;
  if (build_workspace_receipt_line(spec, &tree, &receipt_line) != 0 ||
      write_workspace_receipt(configuration, receipt_line) != 0) {
    (void)fail_errno("workspace protocol: cannot finalize mutation receipt", NULL);
    goto out;
  }
  result = 0;

out:
  if (result != 0) {
    rollback_new_workspace_strategy(spec, &tree, configuration->git_bin, strategy_created);
    if (tree.workspace_created && tree.workspace_fd >= 0) {
      (void)clear_workspace_children(tree.workspace_fd);
      (void)close(tree.workspace_fd);
      tree.workspace_fd = -1;
      (void)unlinkat(tree.base_fd, spec->workspace, AT_REMOVEDIR);
    }
  }
  free(receipt_line);
  close_workspace_tree(&tree);
  return result;
}

static int validate_workspace_receipt_bindings(const struct configuration *configuration,
                                               const struct workspace_receipt_data *receipt) {
  int project_fd = -1;
  int base_fd = -1;
  int workspace_fd = -1;
  int child_fd = -1;
  int result = -1;

  if (open_workspace_directory(configuration, INHERITED_ROOT_PROJECT, receipt->fields[2],
                               receipt->fields[2], &project_fd, NULL) != 0 ||
      validate_directory_identity(project_fd, receipt->project_dev, receipt->project_ino,
                                  receipt->fields[2]) != 0 ||
      open_base_directory(project_fd, receipt->fields[3], false, &base_fd) != 0 ||
      validate_directory_identity(base_fd, receipt->base_dev, receipt->base_ino,
                                  receipt->fields[3]) != 0 ||
      open_directory_component(base_fd, receipt->fields[4], false, &workspace_fd) != 0 ||
      validate_directory_identity(workspace_fd, receipt->workspace_dev, receipt->workspace_ino,
                                  receipt->fields[4]) != 0) {
    errorf("workspace receipt: identity validation failed");
    goto out;
  }
  if (receipt->strategy == WORKSPACE_STRATEGY_BTRFS) {
    if (validate_btrfs_child(workspace_fd, receipt->fields[13], &child_fd) != 0) {
      goto out;
    }
  } else if (receipt->strategy == WORKSPACE_STRATEGY_GIT_WORKTREE) {
    if (open_strategy_child(workspace_fd, receipt->fields[13], &child_fd) != 0) {
      goto out;
    }
  }
  if (child_fd >= 0 &&
      validate_directory_identity(child_fd, receipt->child_dev, receipt->child_ino,
                                  receipt->fields[13]) != 0) {
    goto out;
  }
  result = 0;

out:
  if (child_fd >= 0) {
    (void)close(child_fd);
  }
  if (workspace_fd >= 0) {
    (void)close(workspace_fd);
  }
  if (base_fd >= 0) {
    (void)close(base_fd);
  }
  if (project_fd >= 0) {
    (void)close(project_fd);
  }
  return result;
}

static int mount_tmpfs_beneath(int parent_fd, const char *target_name) {
#if defined(SYS_fsopen) && defined(SYS_fsconfig) && defined(SYS_fsmount) && defined(SYS_move_mount)
  int context_fd = -1;
  int mount_fd = -1;
  int saved_errno;

  context_fd = (int)syscall(SYS_fsopen, "tmpfs", FSOPEN_CLOEXEC);
  if (context_fd < 0 ||
      syscall(SYS_fsconfig, context_fd, FSCONFIG_SET_STRING, "mode", "0700", 0) != 0 ||
      syscall(SYS_fsconfig, context_fd, FSCONFIG_CMD_CREATE, NULL, NULL, 0) != 0) {
    saved_errno = errno;
    if (context_fd >= 0) {
      (void)close(context_fd);
    }
    errno = saved_errno;
    return -1;
  }
  mount_fd = (int)syscall(SYS_fsmount, context_fd, FSMOUNT_CLOEXEC,
                          MOUNT_ATTR_NODEV | MOUNT_ATTR_NOSUID | MOUNT_ATTR_NOEXEC);
  saved_errno = errno;
  (void)close(context_fd);
  errno = saved_errno;
  if (mount_fd < 0) {
    return -1;
  }
  if (syscall(SYS_move_mount, mount_fd, "", parent_fd, target_name,
              MOVE_MOUNT_F_EMPTY_PATH) != 0) {
    saved_errno = errno;
    (void)close(mount_fd);
    errno = saved_errno;
    return -1;
  }
  if (close(mount_fd) != 0) {
    return -1;
  }
  return 0;
#else
  (void)parent_fd;
  (void)target_name;
  errno = ENOSYS;
  return -1;
#endif
}

static int mount_anchor_tmpfs(int root_fd, const struct stat *expected_anchors_stat) {
  struct stat anchors_stat;
  int anchors_fd;

  if (fchdir(root_fd) != 0) {
    return fail_errno("mount anchoring unavailable: cannot enter runtime directory", NULL);
  }
  if (fstatat(root_fd, "anchors", &anchors_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    return fail_errno("unsafe runtime anchors directory", NULL);
  }
  if (!S_ISDIR(anchors_stat.st_mode) || anchors_stat.st_uid != getuid() ||
      (anchors_stat.st_mode & 0777U) != 0700U ||
      anchors_stat.st_dev != expected_anchors_stat->st_dev ||
      anchors_stat.st_ino != expected_anchors_stat->st_ino) {
    errorf("unsafe runtime anchors directory changed before namespace mount");
    return -1;
  }
  anchors_fd = openat(root_fd, "anchors", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (anchors_fd < 0) {
    return fail_errno("unsafe runtime anchors directory", NULL);
  }
  if (directory_is_empty(anchors_fd) != 0) {
    const int saved_errno = errno;

    (void)close(anchors_fd);
    errno = saved_errno;
    return fail_errno("unsafe runtime anchors directory", NULL);
  }
  if (mount_tmpfs_beneath(root_fd, "anchors") != 0) {
    const int saved_errno = errno;

    (void)close(anchors_fd);
    errno = saved_errno;
    return fail_errno("mount anchoring unavailable: cannot mount private anchors tmpfs", NULL);
  }
  if (close(anchors_fd) != 0) {
    return fail_errno("mount anchoring unavailable: cannot close runtime anchors directory", NULL);
  }
  anchors_fd = openat(root_fd, "anchors", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (anchors_fd < 0) {
    return fail_errno("mount anchoring unavailable: cannot open private anchors tmpfs", NULL);
  }
  if (fstat(anchors_fd, &anchors_stat) != 0) {
    const int saved_errno = errno;

    (void)close(anchors_fd);
    errno = saved_errno;
    return fail_errno("mount anchoring unavailable: cannot validate private anchors tmpfs", NULL);
  }
  if (!S_ISDIR(anchors_stat.st_mode) || anchors_stat.st_uid != getuid() ||
      (anchors_stat.st_mode & 0777U) != 0700U) {
    errorf("mount anchoring unavailable: private anchors tmpfs has unsafe mode");
    (void)close(anchors_fd);
    return -1;
  }
  if (fchdir(anchors_fd) != 0) {
    const int saved_errno = errno;

    (void)close(anchors_fd);
    errno = saved_errno;
    return fail_errno("mount anchoring unavailable: cannot enter private anchors tmpfs", NULL);
  }
  if (close(anchors_fd) != 0) {
    return fail_errno("mount anchoring unavailable: cannot close private anchors tmpfs", NULL);
  }
  return 0;
}

static int allocate_anchor_path(const struct configuration *configuration, const char *run_name,
                                size_t source_index, char **path_out) {
  const int required = snprintf(NULL, 0, "%s/anchors/%s/%zu", configuration->anchor_root, run_name,
                                source_index);
  char *path;

  if (required < 0 || (uintmax_t)required > (uintmax_t)(SIZE_MAX - 1U)) {
    errorf("mount anchoring unavailable: anchor path is too long");
    return -1;
  }
  path = malloc((size_t)required + 1U);
  if (path == NULL) {
    errorf("mount anchoring unavailable: cannot allocate anchor path");
    return -1;
  }
  if (snprintf(path, (size_t)required + 1U, "%s/anchors/%s/%zu", configuration->anchor_root,
               run_name, source_index) != required) {
    errorf("mount anchoring unavailable: cannot format anchor path");
    free(path);
    return -1;
  }
  *path_out = path;
  return 0;
}

static int format_run_name(char run_name[64]) {
  const int run_name_length = snprintf(run_name, 64U, "mount-%" PRIdMAX, (intmax_t)getpid());

  if (run_name_length < 0 || (size_t)run_name_length >= 64U) {
    errorf("cannot format per-run anchor directory");
    return -1;
  }
  return 0;
}

static int create_run_anchor_directory(const char *run_name) {
  if (mkdir(run_name, 0700) != 0) {
    return fail_errno("mount anchoring unavailable: cannot create per-run anchors", run_name);
  }
  return 0;
}

static bool is_overlay_src_option(const char *argument) {
  return strcmp(argument, "--overlay-src") == 0 || strncmp(argument, "--overlay-src=", 14U) == 0;
}

static bool is_overlay_option(const char *argument) {
  return strcmp(argument, "--overlay") == 0 || strncmp(argument, "--overlay=", 10U) == 0;
}

static size_t bubblewrap_option_end(const struct configuration *configuration) {
  size_t index;

  for (index = 1U; index < configuration->backend_argc; ++index) {
    if (strcmp(configuration->backend_argv[index], "--") == 0) {
      return index;
    }
  }
  return configuration->backend_argc;
}

static int add_size_checked(size_t *total, size_t amount) {
  if (*total > SIZE_MAX - amount) {
    errno = EOVERFLOW;
    return -1;
  }
  *total += amount;
  return 0;
}

static int overlay_fd_path_length(int file_descriptor, size_t *length_out) {
  char path[64];
  const int length = snprintf(path, sizeof(path), "/proc/self/fd/%d", file_descriptor);

  if (file_descriptor < 0 || length < 0 || (size_t)length >= sizeof(path)) {
    errno = file_descriptor < 0 ? EBADF : EOVERFLOW;
    return -1;
  }
  *length_out = (size_t)length;
  return 0;
}

static int append_overlay_mount_option(char *options, size_t options_size, size_t *offset,
                                       const char *fragment) {
  const size_t length = strlen(fragment);

  if (*offset >= options_size || length > options_size - *offset - 1U) {
    errno = EOVERFLOW;
    return -1;
  }
  memcpy(options + *offset, fragment, length);
  *offset += length;
  options[*offset] = '\0';
  return 0;
}

static int append_overlay_fd_path(char *options, size_t options_size, size_t *offset,
                                  int file_descriptor) {
  char path[64];
  const int length = snprintf(path, sizeof(path), "/proc/self/fd/%d", file_descriptor);

  if (file_descriptor < 0 || length < 0 || (size_t)length >= sizeof(path)) {
    errno = file_descriptor < 0 ? EBADF : EOVERFLOW;
    return -1;
  }
  return append_overlay_mount_option(options, options_size, offset, path);
}

static int build_overlay_mount_options(const struct configuration *configuration,
                                       const size_t *source_indexes, size_t lower_count,
                                       size_t upper_index, size_t work_index, char **options_out) {
  size_t options_length = sizeof("lowerdir=") - 1U;
  size_t index;
  char *options;
  size_t offset = 0U;

  for (index = lower_count; index > 0U; --index) {
    size_t path_length;

    if (overlay_fd_path_length(configuration->sources[source_indexes[index - 1U]].source_fd,
                               &path_length) != 0 ||
        (index != lower_count && add_size_checked(&options_length, 1U) != 0) ||
        add_size_checked(&options_length, path_length) != 0) {
      return -1;
    }
  }
  if (add_size_checked(&options_length, sizeof(",upperdir=") - 1U) != 0 ||
      overlay_fd_path_length(configuration->sources[upper_index].source_fd, &index) != 0 ||
      add_size_checked(&options_length, index) != 0 ||
      add_size_checked(&options_length, sizeof(",workdir=") - 1U) != 0 ||
      overlay_fd_path_length(configuration->sources[work_index].source_fd, &index) != 0 ||
      add_size_checked(&options_length, index) != 0 ||
      add_size_checked(&options_length, sizeof(",userxattr") - 1U) != 0 ||
      options_length == SIZE_MAX) {
    return -1;
  }
  options = malloc(options_length + 1U);
  if (options == NULL) {
    return -1;
  }
  options[0] = '\0';
  if (append_overlay_mount_option(options, options_length + 1U, &offset, "lowerdir=") != 0) {
    free(options);
    return -1;
  }
  for (index = lower_count; index > 0U; --index) {
    if ((index != lower_count &&
         append_overlay_mount_option(options, options_length + 1U, &offset, ":") != 0) ||
        append_overlay_fd_path(options, options_length + 1U, &offset,
                               configuration->sources[source_indexes[index - 1U]].source_fd) != 0) {
      free(options);
      return -1;
    }
  }
  if (append_overlay_mount_option(options, options_length + 1U, &offset, ",upperdir=") != 0 ||
      append_overlay_fd_path(options, options_length + 1U, &offset,
                             configuration->sources[upper_index].source_fd) != 0 ||
      append_overlay_mount_option(options, options_length + 1U, &offset, ",workdir=") != 0 ||
      append_overlay_fd_path(options, options_length + 1U, &offset,
                             configuration->sources[work_index].source_fd) != 0 ||
      append_overlay_mount_option(options, options_length + 1U, &offset, ",userxattr") != 0 ||
      offset != options_length) {
    free(options);
    errno = EOVERFLOW;
    return -1;
  }
  *options_out = options;
  return 0;
}

static int validate_overlay_source(struct configuration *configuration, size_t source_index,
                                   const size_t *group_sources, size_t group_source_count) {
  struct source_spec *source = &configuration->sources[source_index];
  struct stat status;
  size_t index;

  for (index = 0U; index < group_source_count; ++index) {
    if (group_sources[index] == source_index) {
      return bubblewrap_failure("duplicate overlay source token");
    }
  }
  if (source->consumed_by_overlay) {
    return bubblewrap_failure("overlay source token was already consumed");
  }
  if (source->requiredness != SOURCE_REQUIRED || source->absent ||
      source->expected_type != SOURCE_DIRECTORY || source->source_fd < 0) {
    return bubblewrap_failure("overlay source must be a required, present directory");
  }
  if (fstat(source->source_fd, &status) != 0) {
    return bubblewrap_failure_errno("cannot validate overlay source descriptor");
  }
  if (!S_ISDIR(status.st_mode)) {
    return bubblewrap_failure("overlay source descriptor is not a directory");
  }
  return 0;
}

static int overlay_source_for_argument(const struct configuration *configuration,
                                       size_t argument_index, size_t *source_index_out) {
  const ssize_t source_index =
      source_index_for_replacement_index(configuration, argument_index);

  if (source_index < 0 ||
      strcmp(configuration->sources[source_index].token,
             configuration->backend_argv[argument_index]) != 0) {
    return bubblewrap_failure("overlay argument does not match its source replacement");
  }
  *source_index_out = (size_t)source_index;
  return 0;
}

static int mount_bubblewrap_overlay_group(struct configuration *configuration, const char *run_name,
                                          const size_t *source_indexes, size_t lower_count,
                                          size_t upper_index, size_t work_index) {
  char anchor_name[64];
  char relative_anchor[128];
  char *anchor_path = NULL;
  char *options = NULL;
  size_t source_count = lower_count + 2U;
  size_t index;
  const int anchor_name_length =
      snprintf(anchor_name, sizeof(anchor_name), "%zu", source_indexes[0]);
  int relative_length;

  if (anchor_name_length < 0 || (size_t)anchor_name_length >= sizeof(anchor_name)) {
    return bubblewrap_failure("cannot format overlay anchor name");
  }
  relative_length = snprintf(relative_anchor, sizeof(relative_anchor), "%s/%s", run_name, anchor_name);
  if (relative_length < 0 || (size_t)relative_length >= sizeof(relative_anchor)) {
    return bubblewrap_failure("cannot format overlay anchor path");
  }
  if (mkdir(relative_anchor, 0700) != 0) {
    return bubblewrap_failure_errno("cannot create overlay anchor");
  }
  if (allocate_anchor_path(configuration, run_name, source_indexes[0], &anchor_path) != 0) {
    return -1;
  }
  if (build_overlay_mount_options(configuration, source_indexes, lower_count, upper_index, work_index,
                                  &options) != 0) {
    const int saved_errno = errno;

    free(anchor_path);
    errno = saved_errno;
    return bubblewrap_failure_errno("cannot build overlay mount options");
  }
  if (mount("overlay", relative_anchor, "overlay", MS_MGC_VAL | MS_NOSUID | MS_NODEV, options) != 0) {
    const int saved_errno = errno;

    free(options);
    free(anchor_path);
    errno = saved_errno;
    return bubblewrap_failure_errno("cannot mount overlay anchor");
  }
  free(options);
  for (index = 0U; index < source_count; ++index) {
    char *anchor_copy = strdup(anchor_path);

    if (anchor_copy == NULL) {
      free(anchor_path);
      return bubblewrap_failure_errno("cannot allocate overlay anchor path");
    }
    configuration->sources[source_indexes[index]].anchor_path = anchor_copy;
  }
  free(anchor_path);
  for (index = 0U; index < source_count; ++index) {
    struct source_spec *source = &configuration->sources[source_indexes[index]];

    if (close(source->source_fd) != 0) {
      source->source_fd = -1;
      return bubblewrap_failure_errno("cannot close overlay source descriptor");
    }
    source->source_fd = -1;
  }
  for (index = 0U; index < source_count; ++index) {
    configuration->sources[source_indexes[index]].consumed_by_overlay = true;
  }
  return 0;
}

static int compose_bubblewrap_overlays(struct configuration *configuration, const char *run_name) {
  const size_t option_end = bubblewrap_option_end(configuration);
  size_t *group_sources = NULL;
  size_t index = 1U;
  int result = -1;

  if (configuration->backend != BACKEND_BUBBLEWRAP) {
    return 0;
  }
  while (index < option_end) {
    size_t lower_count = 0U;
    size_t upper_index;
    size_t work_index;

    if (!is_overlay_src_option(configuration->backend_argv[index])) {
      if (is_overlay_option(configuration->backend_argv[index])) {
        (void)bubblewrap_failure("--overlay must follow one or more --overlay-src pairs");
        goto out;
      }
      ++index;
      continue;
    }
    if (strcmp(configuration->backend_argv[index], "--overlay-src") != 0) {
      (void)bubblewrap_failure("malformed --overlay-src option");
      goto out;
    }
    if (configuration->source_count == 0U) {
      (void)bubblewrap_failure("--overlay-src has no declared source");
      goto out;
    }
    if (group_sources == NULL) {
      group_sources = calloc(configuration->source_count, sizeof(*group_sources));
      if (group_sources == NULL) {
        (void)bubblewrap_failure_errno("cannot allocate overlay source list");
        goto out;
      }
    }
    while (index < option_end && strcmp(configuration->backend_argv[index], "--overlay-src") == 0) {
      size_t source_index;

      if (option_end - index < 2U || lower_count >= configuration->source_count ||
          overlay_source_for_argument(configuration, index + 1U, &source_index) != 0 ||
          validate_overlay_source(configuration, source_index, group_sources, lower_count) != 0) {
        goto out;
      }
      group_sources[lower_count++] = source_index;
      index += 2U;
    }
    if (index >= option_end || strcmp(configuration->backend_argv[index], "--overlay") != 0 ||
        option_end - index < 4U) {
      (void)bubblewrap_failure("incomplete --overlay group");
      goto out;
    }
    if (overlay_source_for_argument(configuration, index + 1U, &upper_index) != 0 ||
        validate_overlay_source(configuration, upper_index, group_sources, lower_count) != 0) {
      goto out;
    }
    group_sources[lower_count] = upper_index;
    if (overlay_source_for_argument(configuration, index + 2U, &work_index) != 0 ||
        validate_overlay_source(configuration, work_index, group_sources, lower_count + 1U) != 0 ||
        source_index_for_replacement_index(configuration, index + 3U) >= 0) {
      if (source_index_for_replacement_index(configuration, index + 3U) >= 0) {
        (void)bubblewrap_failure("--overlay destination cannot be a source replacement");
      }
      goto out;
    }
    group_sources[lower_count + 1U] = work_index;
    if (mount_bubblewrap_overlay_group(configuration, run_name, group_sources, lower_count,
                                       upper_index, work_index) != 0) {
      goto out;
    }
    index += 4U;
  }
  result = 0;

out:
  free(group_sources);
  return result;
}

static int create_anchors(struct configuration *configuration, const char *run_name) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    struct source_spec *source = &configuration->sources[index];
    char anchor_name[64];
    char source_fd_path[64];
    int anchor_file_descriptor = -1;
    int anchor_name_length;
    int source_fd_path_length;

    if (source->absent || source->consumed_by_overlay) {
      continue;
    }
    if (source->source_fd < 0) {
      errorf("mount anchoring unavailable: source descriptor is unavailable: %s",
             source->absolute_path);
      return -1;
    }
    anchor_name_length = snprintf(anchor_name, sizeof(anchor_name), "%zu", index);
    if (anchor_name_length < 0 || (size_t)anchor_name_length >= sizeof(anchor_name)) {
      errorf("cannot format per-run anchor name");
      return -1;
    }
    {
      char relative_anchor[128];
      const int relative_length =
          snprintf(relative_anchor, sizeof(relative_anchor), "%s/%s", run_name, anchor_name);

      if (relative_length < 0 || (size_t)relative_length >= sizeof(relative_anchor)) {
        errorf("cannot format relative anchor path");
        return -1;
      }
      if (source->expected_type == SOURCE_DIRECTORY) {
        if (mkdir(relative_anchor, 0700) != 0) {
          return fail_errno("mount anchoring unavailable: cannot create directory anchor", relative_anchor);
        }
      } else {
        anchor_file_descriptor =
            open(relative_anchor, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (anchor_file_descriptor < 0) {
          return fail_errno("mount anchoring unavailable: cannot create file anchor", relative_anchor);
        }
        if (close(anchor_file_descriptor) != 0) {
          return fail_errno("mount anchoring unavailable: cannot close file anchor", relative_anchor);
        }
      }
      source_fd_path_length =
          snprintf(source_fd_path, sizeof(source_fd_path), "/proc/self/fd/%d", source->source_fd);
      if (source_fd_path_length < 0 || (size_t)source_fd_path_length >= sizeof(source_fd_path)) {
        errorf("cannot format source descriptor path");
        return -1;
      }
      if (mount(source_fd_path, relative_anchor, NULL, MS_BIND, NULL) != 0) {
        return fail_errno("mount anchoring unavailable: cannot bind source descriptor", source->absolute_path);
      }
    }
    if (close(source->source_fd) != 0) {
      source->source_fd = -1;
      return fail_errno("mount anchoring unavailable: cannot close source descriptor", source->absolute_path);
    }
    source->source_fd = -1;
    if (allocate_anchor_path(configuration, run_name, index, &source->anchor_path) != 0) {
      return -1;
    }
  }
  return 0;
}

static int close_source_fds(struct configuration *configuration) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    struct source_spec *source = &configuration->sources[index];

    if (source->source_fd >= 0 && close(source->source_fd) != 0) {
      source->source_fd = -1;
      return fail_errno("mount anchoring unavailable: cannot close source descriptor",
                        source->absolute_path);
    }
    source->source_fd = -1;
  }
  return 0;
}

static int close_inherited_root_fds(struct configuration *configuration) {
  size_t index;

  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    struct inherited_fd_spec *root = &configuration->inherited_roots[index];

    if (root->file_descriptor >= 0 && close(root->file_descriptor) != 0) {
      root->file_descriptor = -1;
      return fail_errno("mount anchoring unavailable: cannot close inherited root descriptor",
                        root->display_path);
    }
    root->file_descriptor = -1;
  }
  return 0;
}

static int replace_once(const char *original, const char *token, const char *replacement,
                        char **result_out) {
  const char *position = strstr(original, token);
  const size_t original_length = strlen(original);
  const size_t token_length = strlen(token);
  const size_t replacement_length = strlen(replacement);
  size_t prefix_length;
  size_t result_length;
  char *result;

  if (position == NULL || original_length < token_length ||
      replacement_length > SIZE_MAX - (original_length - token_length) - 1U) {
    errorf("cannot replace source token safely");
    return -1;
  }
  prefix_length = (size_t)(position - original);
  result_length = original_length - token_length + replacement_length;
  result = malloc(result_length + 1U);
  if (result == NULL) {
    errorf("cannot allocate replaced backend argument");
    return -1;
  }
  memcpy(result, original, prefix_length);
  memcpy(result + prefix_length, replacement, replacement_length);
  memcpy(result + prefix_length + replacement_length, position + token_length,
         original_length - prefix_length - token_length + 1U);
  *result_out = result;
  return 0;
}

static void free_argument_vector(char **arguments, size_t count) {
  size_t index;

  if (arguments == NULL) {
    return;
  }
  for (index = 0U; index < count; ++index) {
    free(arguments[index]);
  }
  free(arguments);
}

static bool is_consumed_overlay_anchor_path(const struct configuration *configuration,
                                            const char *path) {
  size_t index;

  for (index = 0U; index < configuration->source_count; ++index) {
    const struct source_spec *source = &configuration->sources[index];

    if (source->consumed_by_overlay && source->anchor_path != NULL &&
        strcmp(source->anchor_path, path) == 0) {
      return true;
    }
  }
  return false;
}

static size_t rewritten_bubblewrap_option_end(char *const *arguments, size_t argument_count) {
  size_t index;

  for (index = 1U; index < argument_count; ++index) {
    if (strcmp(arguments[index], "--") == 0) {
      return index;
    }
  }
  return argument_count;
}

static int collapse_bubblewrap_overlay_groups(const struct configuration *configuration,
                                              char **arguments, size_t *argument_count_out) {
  size_t argument_count = *argument_count_out;
  size_t option_end = rewritten_bubblewrap_option_end(arguments, argument_count);
  size_t index = 1U;

  while (index < option_end) {
    size_t group_start;
    size_t overlay_index;
    const char *overlay_anchor;
    size_t removal_count;
    size_t free_index;
    char *bind_option;
    char *destination;

    if (!is_overlay_src_option(arguments[index])) {
      if (is_overlay_option(arguments[index])) {
        return bubblewrap_failure("--overlay must follow one or more --overlay-src pairs");
      }
      ++index;
      continue;
    }
    if (strcmp(arguments[index], "--overlay-src") != 0) {
      return bubblewrap_failure("malformed --overlay-src option in rewritten backend argv");
    }
    group_start = index;
    overlay_anchor = NULL;
    while (index < option_end && strcmp(arguments[index], "--overlay-src") == 0) {
      const char *candidate;

      if (option_end - index < 2U) {
        return bubblewrap_failure("incomplete --overlay-src pair in rewritten backend argv");
      }
      candidate = arguments[index + 1U];
      if (!is_consumed_overlay_anchor_path(configuration, candidate)) {
        return bubblewrap_failure("--overlay-src was not replaced by a private overlay anchor");
      }
      if (overlay_anchor == NULL) {
        overlay_anchor = candidate;
      } else if (strcmp(overlay_anchor, candidate) != 0) {
        return bubblewrap_failure("overlay group has differing private anchor paths");
      }
      index += 2U;
    }
    overlay_index = index;
    if (overlay_index >= option_end || strcmp(arguments[overlay_index], "--overlay") != 0 ||
        option_end - overlay_index < 4U) {
      return bubblewrap_failure("incomplete --overlay group in rewritten backend argv");
    }
    if (strcmp(arguments[overlay_index + 1U], overlay_anchor) != 0 ||
        strcmp(arguments[overlay_index + 2U], overlay_anchor) != 0 ||
        !is_consumed_overlay_anchor_path(configuration, arguments[overlay_index + 1U]) ||
        !is_consumed_overlay_anchor_path(configuration, arguments[overlay_index + 2U])) {
      return bubblewrap_failure("overlay group has differing private anchor paths");
    }
    bind_option = strdup("--bind");
    if (bind_option == NULL) {
      return bubblewrap_failure_errno("cannot allocate collapsed overlay bind option");
    }
    destination = arguments[overlay_index + 3U];
    free(arguments[group_start]);
    arguments[group_start] = bind_option;
    for (free_index = group_start + 2U; free_index <= overlay_index + 2U; ++free_index) {
      free(arguments[free_index]);
    }
    arguments[group_start + 2U] = destination;
    removal_count = overlay_index - group_start + 1U;
    memmove(&arguments[group_start + 3U], &arguments[overlay_index + 4U],
            (argument_count - overlay_index - 4U) * sizeof(*arguments));
    argument_count -= removal_count;
    memset(&arguments[argument_count], 0, removal_count * sizeof(*arguments));
    option_end -= removal_count;
    index = group_start + 3U;
  }
  *argument_count_out = argument_count;
  return 0;
}

static int build_backend_argv(const struct configuration *configuration, char ***arguments_out,
                               char ***exec_arguments_out, size_t *argument_count_out) {
  char **arguments = NULL;
  char **exec_arguments = NULL;
  bool *deleted_sources = NULL;
  size_t index;
  size_t argument_count = configuration->backend_argc;

  arguments = calloc(configuration->backend_argc, sizeof(*arguments));
  exec_arguments = calloc(configuration->backend_argc + 1U, sizeof(*exec_arguments));
  if (configuration->source_count > 0U) {
    deleted_sources = calloc(configuration->source_count, sizeof(*deleted_sources));
  }
  if (arguments == NULL || exec_arguments == NULL ||
      (configuration->source_count > 0U && deleted_sources == NULL)) {
    errorf("cannot allocate rewritten backend argv");
    free(arguments);
    free(exec_arguments);
    free(deleted_sources);
    return -1;
  }
  for (index = 0U; index < configuration->backend_argc; ++index) {
    arguments[index] = strdup(configuration->backend_argv[index]);
    if (arguments[index] == NULL) {
      errorf("cannot copy backend argv");
      goto failure;
    }
  }
  if (configuration->backend == BACKEND_BUBBLEWRAP && configuration->bubblewrap_rewrite_identity) {
    char uid_text[32];
    char gid_text[32];
    int uid_length;
    int gid_length;

    uid_length = snprintf(uid_text, sizeof(uid_text), "%" PRIuMAX,
                          (uintmax_t)configuration->bubblewrap_uid);
    gid_length = snprintf(gid_text, sizeof(gid_text), "%" PRIuMAX,
                          (uintmax_t)configuration->bubblewrap_gid);
    if (uid_length < 0 || (size_t)uid_length >= sizeof(uid_text) || gid_length < 0 ||
        (size_t)gid_length >= sizeof(gid_text)) {
      errorf("cannot format fallback bubblewrap identity");
      goto failure;
    }
    for (index = 1U; index + 1U < configuration->backend_argc; ++index) {
      if (strcmp(arguments[index], "--uid") == 0) {
        char *replacement_uid = strdup(uid_text);
        if (replacement_uid == NULL) {
          errorf("cannot rewrite fallback bubblewrap uid");
          goto failure;
        }
        free(arguments[index + 1U]);
        arguments[index + 1U] = replacement_uid;
      } else if (strcmp(arguments[index], "--gid") == 0) {
        char *replacement_gid = strdup(gid_text);
        if (replacement_gid == NULL) {
          errorf("cannot rewrite fallback bubblewrap gid");
          goto failure;
        }
        free(arguments[index + 1U]);
        arguments[index + 1U] = replacement_gid;
      }
    }
  }
  for (index = 0U; index < configuration->source_count; ++index) {
    const struct source_spec *source = &configuration->sources[index];

    if (!source->absent) {
      char *replaced = NULL;

      if (replace_once(configuration->backend_argv[source->replacement_index], source->token,
                       source->anchor_path, &replaced) != 0) {
        goto failure;
      }
      free(arguments[source->replacement_index]);
      arguments[source->replacement_index] = replaced;
    }
  }
  for (;;) {
    size_t source_index = SIZE_MAX;

    for (index = 0U; index < configuration->source_count; ++index) {
      const struct source_spec *source = &configuration->sources[index];

      if (source->absent && !deleted_sources[index] &&
          (source_index == SIZE_MAX || source->drop_start >
                                       configuration->sources[source_index].drop_start)) {
        source_index = index;
      }
    }
    if (source_index == SIZE_MAX) {
      break;
    }
    {
      const struct source_spec *source = &configuration->sources[source_index];
      size_t drop_index;

      for (drop_index = source->drop_start; drop_index < source->drop_start + source->drop_count;
           ++drop_index) {
        free(arguments[drop_index]);
      }
      memmove(&arguments[source->drop_start], &arguments[source->drop_start + source->drop_count],
              (argument_count - source->drop_start - source->drop_count) * sizeof(*arguments));
      argument_count -= source->drop_count;
      memset(&arguments[argument_count], 0, source->drop_count * sizeof(*arguments));
      deleted_sources[source_index] = true;
    }
  }
  if (configuration->backend == BACKEND_BUBBLEWRAP &&
      collapse_bubblewrap_overlay_groups(configuration, arguments, &argument_count) != 0) {
    goto failure;
  }
  for (index = 0U; index < argument_count; ++index) {
    size_t source_index;

    if (strstr(arguments[index], "@OCSB_SOURCE_") != NULL) {
      errorf("leftover source token in rewritten backend argv");
      goto failure;
    }
    if (contains_proc_fd_path(arguments[index])) {
      errorf("rewritten backend argv contains forbidden /proc/*/fd/ path");
      goto failure;
    }
    if (configuration->backend == BACKEND_BUBBLEWRAP &&
        (is_overlay_src_option(arguments[index]) || is_overlay_option(arguments[index]))) {
      (void)bubblewrap_failure("rewritten backend argv contains an unsafe overlay argument");
      goto failure;
    }
    if (configuration->backend == BACKEND_BUBBLEWRAP) {
      for (source_index = 0U; source_index < configuration->source_count; ++source_index) {
        const struct source_spec *source = &configuration->sources[source_index];

        if (source->consumed_by_overlay &&
            strcmp(arguments[index], source->absolute_path) == 0) {
          (void)bubblewrap_failure("rewritten backend argv contains an original overlay source path");
          goto failure;
        }
      }
    }
    exec_arguments[index] = arguments[index];
  }
  exec_arguments[argument_count] = NULL;
  free(deleted_sources);
  *arguments_out = arguments;
  *exec_arguments_out = exec_arguments;
  *argument_count_out = argument_count;
  return 0;

failure:
  free(deleted_sources);
  free(exec_arguments);
  free_argument_vector(arguments, argument_count);
  return -1;
}

static int rewrite_and_exec_backend(const struct configuration *configuration,
                                    char ***rewritten_arguments_out, char ***exec_arguments_out,
                                    size_t *rewritten_argument_count_out) {
  if (build_backend_argv(configuration, rewritten_arguments_out, exec_arguments_out,
                         rewritten_argument_count_out) != 0) {
    return -1;
  }
  execve((*exec_arguments_out)[0], *exec_arguments_out, environ);
  return fail_errno("cannot exec backend", (*exec_arguments_out)[0]);
}

#ifdef OCSB_MOUNT_ANCHOR_MANIFEST_UNIT
static bool manifest_unit_requested(void) {
  const char *value = getenv("OCSB_MOUNT_ANCHOR_RUN_MANIFEST_UNIT");

  return value != NULL && strcmp(value, "1") == 0;
}

static int run_manifest_unit(struct configuration *configuration, char ***rewritten_arguments_out,
                              char ***exec_arguments_out, size_t *rewritten_argument_count_out) {
  size_t index;

  if (open_sources(configuration) != 0) {
    return -1;
  }
  for (index = 0U; index < configuration->source_count; ++index) {
    struct source_spec *source = &configuration->sources[index];

    if (source->absent) {
      continue;
    }
    if (source->source_fd < 0) {
      errorf("mount anchoring unavailable: source descriptor is unavailable: %s",
             source->absolute_path);
      return -1;
    }
    if (close(source->source_fd) != 0) {
      source->source_fd = -1;
      return fail_errno("mount anchoring unavailable: cannot close source descriptor",
                        source->absolute_path);
    }
    source->source_fd = -1;
    source->anchor_path = strdup(source->absolute_path);
    if (source->anchor_path == NULL) {
      errorf("cannot allocate manifest-unit source path");
      return -1;
    }
  }
  if (close_source_fds(configuration) != 0 || close_inherited_root_fds(configuration) != 0) {
    return -1;
  }
  return rewrite_and_exec_backend(configuration, rewritten_arguments_out, exec_arguments_out,
                                  rewritten_argument_count_out);
}
#endif

static void cleanup_configuration(struct configuration *configuration) {
  size_t index;

#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  (void)close_test_hook_fds(configuration);
#endif
  for (index = 0U; index < configuration->source_count; ++index) {
    if (configuration->sources[index].source_fd >= 0) {
      (void)close(configuration->sources[index].source_fd);
    }
    free(configuration->sources[index].anchor_path);
    free(configuration->sources[index].storage);
  }
  for (index = 0U; index < configuration->inherited_root_count; ++index) {
    if (configuration->inherited_roots[index].file_descriptor >= 0) {
      (void)close(configuration->inherited_roots[index].file_descriptor);
    }
    free(configuration->inherited_roots[index].storage);
  }
  for (index = 0U; index < configuration->replacement_count; ++index) {
    free(configuration->replacements[index].storage);
  }
  free(configuration->sources);
  free(configuration->inherited_roots);
  free(configuration->replacements);
  free(configuration->anchor_root);
  free(configuration->mutation_spec.storage);
  free(configuration->workspace_receipt_path);
  free(configuration->workspace_receipt_parent);
  free(configuration->workspace_receipt_name);
  free(configuration->workspace_nonce);
  free(configuration->workspace_project);
  free(configuration->workspace_base);
  free(configuration->workspace_name);
  free(configuration->git_bin);
}

int main(int argc, char **argv) {
  struct configuration configuration = {
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
    .test_before_inherited_mutation_open_ready_fd = -1,
    .test_before_inherited_mutation_open_release_fd = -1,
    .test_before_inherited_final_open_ready_fd = -1,
    .test_before_inherited_final_open_release_fd = -1,
    .test_before_mutation_ready_fd = -1,
    .test_before_mutation_release_fd = -1,
    .test_before_receipt_open_ready_fd = -1,
    .test_before_receipt_open_release_fd = -1,
    .test_before_receipt_consume_ready_fd = -1,
    .test_before_receipt_consume_release_fd = -1,
    .test_after_moved_guard_validation_ready_fd = -1,
    .test_after_moved_guard_validation_release_fd = -1,
    .test_after_quarantined_receipt_validation_ready_fd = -1,
    .test_after_quarantined_receipt_validation_release_fd = -1,
#endif
  };
  struct stat root_stat;
  struct stat anchors_stat;
  int runtime_root_fd = -1;
  int original_cwd_fd = -1;
  char **rewritten_arguments = NULL;
  char **exec_arguments = NULL;
  struct workspace_receipt_data workspace_receipt = { .parent_fd = -1, .receipt_fd = -1 };
  bool workspace_receipt_loaded = false;
  char run_name[64];
  size_t rewritten_argument_count = 0U;
  int result = 1;

  if (parse_cli(argc, argv, &configuration) != 0) {
    goto cleanup;
  }
  if (configuration.mutation_only) {
    if (execute_workspace_mutation(&configuration) == 0) {
      result = 0;
    }
    goto cleanup;
  }
  if (validate_backend_namespace(&configuration) != 0 || validate_manifest(&configuration) != 0) {
    goto cleanup;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_inherited_final_open_hook(&configuration) != 0) {
    goto cleanup;
  }
#endif
#ifdef OCSB_MOUNT_ANCHOR_MANIFEST_UNIT
  if (manifest_unit_requested()) {
    if (configuration.workspace_receipt_set) {
      const int receipt_result = load_workspace_receipt(&configuration, &workspace_receipt);

      if (receipt_result != 0) {
        if (receipt_result > 0) {
          discard_nonce_matching_workspace_receipt(&configuration, &workspace_receipt);
        }
        goto cleanup;
      }
      workspace_receipt_loaded = true;
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
      if (wait_for_test_receipt_open_hook(&configuration) != 0) {
        goto cleanup;
      }
#endif
      if (validate_workspace_receipt_bindings(&configuration, &workspace_receipt) != 0) {
        discard_nonce_matching_workspace_receipt(&configuration, &workspace_receipt);
        goto cleanup;
      }
      if (consume_workspace_receipt(&configuration, &workspace_receipt) != 0) {
        goto cleanup;
      }
      free_workspace_receipt(&workspace_receipt);
      workspace_receipt_loaded = false;
    }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
    if (close_test_hook_fds(&configuration) != 0) {
      (void)fail_errno("test hook: cannot close hook file descriptor", NULL);
      goto cleanup;
    }
#endif
    (void)run_manifest_unit(&configuration, &rewritten_arguments, &exec_arguments,
                            &rewritten_argument_count);
    goto cleanup;
  }
#endif
  if (configuration.workspace_receipt_set) {
    const int receipt_result = load_workspace_receipt(&configuration, &workspace_receipt);

    if (receipt_result != 0) {
      if (receipt_result > 0) {
        discard_nonce_matching_workspace_receipt(&configuration, &workspace_receipt);
      }
      goto cleanup;
    }
    workspace_receipt_loaded = true;
  }
  if (prepare_anchor_root(&configuration, &runtime_root_fd, &root_stat, &anchors_stat) != 0) {
    goto cleanup;
  }
  original_cwd_fd = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (original_cwd_fd < 0) {
    (void)fail_errno("mount anchoring unavailable: cannot preserve current working directory", NULL);
    goto cleanup;
  }
  if (setup_namespace(&configuration, &original_cwd_fd) != 0) {
    goto cleanup;
  }
  if (close(runtime_root_fd) != 0) {
    runtime_root_fd = -1;
    (void)fail_errno("mount anchoring unavailable: cannot close pre-namespace runtime directory",
                     NULL);
    goto cleanup;
  }
  runtime_root_fd = -1;
  if (reopen_anchor_root_in_namespace(&configuration, &root_stat, &runtime_root_fd) != 0 ||
      mount_anchor_tmpfs(runtime_root_fd, &anchors_stat) != 0) {
    goto cleanup;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (wait_for_test_receipt_open_hook(&configuration) != 0) {
    goto cleanup;
  }
#endif
  if (workspace_receipt_loaded &&
      validate_workspace_receipt_bindings(&configuration, &workspace_receipt) != 0) {
    discard_nonce_matching_workspace_receipt(&configuration, &workspace_receipt);
    free_workspace_receipt(&workspace_receipt);
    workspace_receipt_loaded = false;
    goto cleanup;
  }
  if (open_sources(&configuration) != 0 ||
      format_run_name(run_name) != 0 || create_run_anchor_directory(run_name) != 0 ||
      compose_bubblewrap_overlays(&configuration, run_name) != 0 ||
      create_anchors(&configuration, run_name) != 0) {
    goto cleanup;
  }
  if (close_source_fds(&configuration) != 0 || close_inherited_root_fds(&configuration) != 0) {
    goto cleanup;
  }
  if (fchdir(original_cwd_fd) != 0) {
    (void)fail_errno("mount anchoring unavailable: cannot restore current working directory", NULL);
    goto cleanup;
  }
  if (close(runtime_root_fd) != 0) {
    runtime_root_fd = -1;
    (void)fail_errno("mount anchoring unavailable: cannot close runtime directory", NULL);
    goto cleanup;
  }
  runtime_root_fd = -1;
  if (close(original_cwd_fd) != 0) {
    original_cwd_fd = -1;
    (void)fail_errno("mount anchoring unavailable: cannot close original working directory", NULL);
    goto cleanup;
  }
  original_cwd_fd = -1;
  if (workspace_receipt_loaded &&
      consume_workspace_receipt(&configuration, &workspace_receipt) != 0) {
    goto cleanup;
  }
  if (workspace_receipt_loaded) {
    free_workspace_receipt(&workspace_receipt);
    workspace_receipt_loaded = false;
  }
#ifdef OCSB_MOUNT_ANCHOR_TEST_HOOKS
  if (close_test_hook_fds(&configuration) != 0) {
    (void)fail_errno("test hook: cannot close hook file descriptor", NULL);
    goto cleanup;
  }
#endif
  if (rewrite_and_exec_backend(&configuration, &rewritten_arguments, &exec_arguments,
                               &rewritten_argument_count) != 0) {
    goto cleanup;
  }

cleanup:
  if (workspace_receipt_loaded) {
    discard_nonce_matching_workspace_receipt(&configuration, &workspace_receipt);
    workspace_receipt_loaded = false;
  }
  if (runtime_root_fd >= 0) {
    (void)close(runtime_root_fd);
  }
  if (original_cwd_fd >= 0) {
    (void)close(original_cwd_fd);
  }
  free(exec_arguments);
  free_argument_vector(rewritten_arguments, rewritten_argument_count);
  free_workspace_receipt(&workspace_receipt);
  cleanup_configuration(&configuration);
  return result;
}
