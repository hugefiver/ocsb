#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/*
 * This deliberately does not emulate a container runtime.  It receives the
 * final backend argv, selects the declared mount by destination, then races
 * the backend source pathname only after the mount-anchor helper has exec'd
 * us.  The child has no inherited descriptor which could keep a source alive.
 */

static void fail(const char *message) {
  fprintf(stderr, "fake-anchor-runtime: %s\n", message);
  exit(64);
}

static const char *required_env(const char *name) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0') {
    fprintf(stderr, "fake-anchor-runtime: missing %s\n", name);
    exit(64);
  }
  return value;
}

static int write_all(int fd, const char *text) {
  size_t remaining = strlen(text);
  const char *cursor = text;

  while (remaining > 0) {
    ssize_t written = write(fd, cursor, remaining);
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

static int write_text_file(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  int result;

  if (fd < 0) {
    return -1;
  }
  result = write_all(fd, text);
  if (close(fd) != 0 && result == 0) {
    result = -1;
  }
  return result;
}

static int write_atomic_text_file(const char *path, const char *text) {
  char temporary[PATH_MAX];
  const int length = snprintf(temporary, sizeof(temporary), "%s.tmp.%ld", path, (long)getpid());

  if (length < 0 || (size_t)length >= sizeof(temporary) || write_text_file(temporary, text) != 0) {
    return -1;
  }
  if (rename(temporary, path) != 0) {
    const int saved_errno = errno;

    (void)unlink(temporary);
    errno = saved_errno;
    return -1;
  }
  return 0;
}

static int wait_for_file(const char *path, unsigned int attempts) {
  struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000L };
  unsigned int attempt;

  for (attempt = 0; attempt < attempts; ++attempt) {
    if (access(path, F_OK) == 0) {
      return 0;
    }
    if (errno != ENOENT) {
      return -1;
    }
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
    }
    delay.tv_sec = 0;
    delay.tv_nsec = 10000000L;
  }
  errno = ETIMEDOUT;
  return -1;
}

static int close_extra_fds(void) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, 3U, UINT_MAX, 0U) == 0) {
    return 0;
  }
#endif

  DIR *directory = opendir("/proc/self/fd");
  struct dirent *entry;
  int directory_fd;

  if (directory == NULL) {
    return -1;
  }
  directory_fd = dirfd(directory);
  while ((entry = readdir(directory)) != NULL) {
    char *end = NULL;
    long descriptor;

    errno = 0;
    descriptor = strtol(entry->d_name, &end, 10);
    if (errno != 0 || end == entry->d_name || *end != '\0' || descriptor <= 2 ||
        descriptor > INT_MAX || descriptor == directory_fd) {
      continue;
    }
    (void)close((int)descriptor);
  }
  return closedir(directory);
}

static char *duplicate_segment(const char *begin, size_t length) {
  char *result = malloc(length + 1U);

  if (result == NULL) {
    return NULL;
  }
  memcpy(result, begin, length);
  result[length] = '\0';
  return result;
}

static int argument_contains_source_token(const char *argument) {
  return strstr(argument, "@OCSB_SOURCE_") != NULL;
}

static int source_is_private_anchor(const char *source) {
  const char *prefix = required_env("FAKE_ANCHOR_PRIVATE_PREFIX");
  const size_t prefix_length = strlen(prefix);

  if (strncmp(source, "/proc/self/fd/", strlen("/proc/self/fd/")) == 0 ||
      prefix_length == 0U || strncmp(source, prefix, prefix_length) != 0) {
    return -1;
  }
  return 0;
}

static int validate_bwrap_sources(int argc, char **argv) {
  int index;

  for (index = 2; index < argc; ++index) {
    if (strcmp(argv[index], "--bind") == 0 || strcmp(argv[index], "--ro-bind") == 0 ||
        strcmp(argv[index], "--bind-try") == 0 || strcmp(argv[index], "--ro-bind-try") == 0) {
      if (index + 2 >= argc || source_is_private_anchor(argv[index + 1]) != 0) {
        return -1;
      }
      index += 2;
    } else if (strcmp(argv[index], "--overlay-src") == 0) {
      if (index + 1 >= argc || source_is_private_anchor(argv[index + 1]) != 0) {
        return -1;
      }
      ++index;
    } else if (strcmp(argv[index], "--overlay") == 0) {
      if (index + 3 >= argc || source_is_private_anchor(argv[index + 1]) != 0 ||
          source_is_private_anchor(argv[index + 2]) != 0) {
        return -1;
      }
      index += 3;
    }
  }
  return 0;
}

static int validate_volume_source(const char *value) {
  const char *first_colon = strchr(value, ':');
  const char *second_colon;

  if (first_colon == NULL || first_colon == value) {
    return -1;
  }
  second_colon = strchr(first_colon + 1, ':');
  if (second_colon == NULL || second_colon == first_colon + 1 ||
      strchr(second_colon + 1, ':') != NULL) {
    return -1;
  }
  {
    char *source = duplicate_segment(value, (size_t)(first_colon - value));
    int result;

    if (source == NULL) {
      return -1;
    }
    result = source_is_private_anchor(source);
    free(source);
    return result;
  }
}

static int validate_podman_sources(int argc, char **argv) {
  int index;
  int rootfs_count = 0;

  for (index = 2; index < argc; ++index) {
    if (strcmp(argv[index], "--volume") == 0) {
      if (index + 1 >= argc || validate_volume_source(argv[index + 1]) != 0) {
        return -1;
      }
      ++index;
    } else if (strcmp(argv[index], "--rootfs") == 0) {
      if (index + 1 >= argc || source_is_private_anchor(argv[index + 1]) != 0) {
        return -1;
      }
      ++rootfs_count;
      ++index;
    }
  }
  return rootfs_count == 1 ? 0 : -1;
}

static int validate_nspawn_bind(const char *value) {
  const char *colon = strchr(value, ':');
  char *source;
  int result;

  if (colon == NULL || colon == value || colon[1] == '\0' || strchr(colon + 1, ':') != NULL) {
    return -1;
  }
  source = duplicate_segment(value, (size_t)(colon - value));
  if (source == NULL) {
    return -1;
  }
  result = source_is_private_anchor(source);
  free(source);
  return result;
}

static int validate_nspawn_sources(int argc, char **argv) {
  static const char directory_prefix[] = "--directory=";
  static const char bind_prefix[] = "--bind=";
  static const char bind_ro_prefix[] = "--bind-ro=";
  int index;
  int directory_count = 0;

  for (index = 2; index < argc; ++index) {
    if (strncmp(argv[index], directory_prefix, sizeof(directory_prefix) - 1U) == 0) {
      if (source_is_private_anchor(argv[index] + sizeof(directory_prefix) - 1U) != 0) {
        return -1;
      }
      ++directory_count;
    } else if (strcmp(argv[index], "--directory") == 0) {
      if (index + 1 >= argc || source_is_private_anchor(argv[index + 1]) != 0) {
        return -1;
      }
      ++directory_count;
      ++index;
    } else if (strncmp(argv[index], bind_prefix, sizeof(bind_prefix) - 1U) == 0) {
      if (validate_nspawn_bind(argv[index] + sizeof(bind_prefix) - 1U) != 0) {
        return -1;
      }
    } else if (strcmp(argv[index], "--bind") == 0 || strcmp(argv[index], "--bind-ro") == 0) {
      if (index + 1 >= argc || validate_nspawn_bind(argv[index + 1]) != 0) {
        return -1;
      }
      ++index;
    } else if (strncmp(argv[index], bind_ro_prefix, sizeof(bind_ro_prefix) - 1U) == 0 &&
               validate_nspawn_bind(argv[index] + sizeof(bind_ro_prefix) - 1U) != 0) {
      return -1;
    }
  }
  return directory_count == 1 ? 0 : -1;
}

static int validate_backend_sources(const char *backend, int argc, char **argv) {
  int index;

  for (index = 2; index < argc; ++index) {
    if (argument_contains_source_token(argv[index])) {
      return -1;
    }
  }
  if (strcmp(backend, "bubblewrap") == 0) {
    return validate_bwrap_sources(argc, argv);
  }
  if (strcmp(backend, "podman") == 0) {
    return validate_podman_sources(argc, argv);
  }
  if (strcmp(backend, "nspawn") == 0) {
    return validate_nspawn_sources(argc, argv);
  }
  return -1;
}

static char *find_bwrap_source(int argc, char **argv, const char *destination) {
  int index;

  for (index = 2; index + 2 < argc; ++index) {
    if ((strcmp(argv[index], "--bind") == 0 || strcmp(argv[index], "--ro-bind") == 0 ||
         strcmp(argv[index], "--bind-try") == 0 || strcmp(argv[index], "--ro-bind-try") == 0) &&
        strcmp(argv[index + 2], destination) == 0) {
      return strdup(argv[index + 1]);
    }
  }
  return NULL;
}

static char *find_volume_source(int argc, char **argv, const char *destination) {
  int index;

  for (index = 2; index + 1 < argc; ++index) {
    const char *value;
    const char *first_colon;
    const char *second_colon;

    if (strcmp(argv[index], "--volume") != 0) {
      continue;
    }
    value = argv[index + 1];
    first_colon = strchr(value, ':');
    if (first_colon == NULL) {
      continue;
    }
    second_colon = strchr(first_colon + 1, ':');
    if (second_colon == NULL || strchr(second_colon + 1, ':') != NULL) {
      continue;
    }
    if (strlen(destination) == (size_t)(second_colon - first_colon - 1) &&
        strncmp(first_colon + 1, destination, strlen(destination)) == 0) {
      return duplicate_segment(value, (size_t)(first_colon - value));
    }
  }
  return NULL;
}

static char *find_nspawn_source(int argc, char **argv, const char *destination) {
  static const char bind_prefix[] = "--bind=";
  static const char bind_ro_prefix[] = "--bind-ro=";
  int index;

  for (index = 2; index < argc; ++index) {
    const char *value = NULL;
    const char *colon;

    if (strncmp(argv[index], bind_prefix, sizeof(bind_prefix) - 1U) == 0) {
      value = argv[index] + sizeof(bind_prefix) - 1U;
    } else if (strncmp(argv[index], bind_ro_prefix, sizeof(bind_ro_prefix) - 1U) == 0) {
      value = argv[index] + sizeof(bind_ro_prefix) - 1U;
    }
    if (value == NULL || (colon = strchr(value, ':')) == NULL) {
      continue;
    }
    if (strcmp(colon + 1, destination) == 0) {
      return duplicate_segment(value, (size_t)(colon - value));
    }
  }
  return NULL;
}

static char *find_source(const char *backend, int argc, char **argv, const char *destination) {
  if (strcmp(backend, "bubblewrap") == 0) {
    return find_bwrap_source(argc, argv, destination);
  }
  if (strcmp(backend, "podman") == 0) {
    return find_volume_source(argc, argv, destination);
  }
  if (strcmp(backend, "nspawn") == 0) {
    return find_nspawn_source(argc, argv, destination);
  }
  return NULL;
}

static const char *find_bwrap_environment_value(int argc, char **argv, const char *name) {
  int index;

  for (index = 2; index + 2 < argc; ++index) {
    if (strcmp(argv[index], "--setenv") == 0 && strcmp(argv[index + 1], name) == 0) {
      return argv[index + 2];
    }
  }
  return NULL;
}

static int read_workspace_marker(const char *source, const char *workspace, char *observation,
                                 size_t observation_size) {
  static const char suffix[] = "/.ocsb/";
  static const char marker_suffix[] = "/marker";
  const size_t source_length = strlen(source);
  const size_t workspace_length = strlen(workspace);
  char *path;
  int descriptor;
  ssize_t count;

  if (source_length > SIZE_MAX - sizeof(suffix) ||
      workspace_length > SIZE_MAX - source_length - sizeof(suffix) ||
      sizeof(marker_suffix) > SIZE_MAX - source_length - sizeof(suffix) - workspace_length) {
    errno = ENAMETOOLONG;
    return -1;
  }
  path = malloc(source_length + sizeof(suffix) - 1U + workspace_length + sizeof(marker_suffix));
  if (path == NULL) {
    return -1;
  }
  memcpy(path, source, source_length);
  memcpy(path + source_length, suffix, sizeof(suffix) - 1U);
  memcpy(path + source_length + sizeof(suffix) - 1U, workspace, workspace_length);
  memcpy(path + source_length + sizeof(suffix) - 1U + workspace_length, marker_suffix,
         sizeof(marker_suffix));

  descriptor = open(path, O_RDONLY | O_CLOEXEC);
  free(path);
  if (descriptor < 0) {
    if (errno == ENOENT) {
      if (snprintf(observation, observation_size, "absent") >= (int)observation_size) {
        errno = EOVERFLOW;
        return -1;
      }
      return 0;
    }
    return -1;
  }
  count = read(descriptor, observation, observation_size - 1U);
  if (close(descriptor) != 0 && count >= 0) {
    count = -1;
  }
  if (count < 0) {
    return -1;
  }
  observation[count] = '\0';
  observation[strcspn(observation, "\r\n")] = '\0';
  if (strcmp(observation, "original") != 0 && strcmp(observation, "replacement") != 0) {
    errno = EINVAL;
    return -1;
  }
  return 0;
}

static int run_mutation_backend_sentinel(int argc, char **argv) {
  const char *sentinel = required_env("OCSB_MUTATION_BACKEND_SENTINEL");
  const char *workspace = find_bwrap_environment_value(argc, argv, "OCSB_WORKSPACE");
  char *source = find_bwrap_source(argc, argv, "/workspace");
  char observation[32];
  char record[64];

  if (workspace == NULL || source == NULL || source_is_private_anchor(source) != 0 ||
      read_workspace_marker(source, workspace, observation, sizeof(observation)) != 0 ||
      snprintf(record, sizeof(record), "observed=%s\n", observation) >= (int)sizeof(record) ||
      write_atomic_text_file(sentinel, record) != 0) {
    free(source);
    return -1;
  }
  free(source);
  return 0;
}

static int require_pair(int argc, char **argv, const char *flag, const char *value) {
  int index;
  int matches = 0;

  for (index = 2; index + 1 < argc; ++index) {
    if (strcmp(argv[index], flag) == 0 && strcmp(argv[index + 1], value) == 0) {
      ++matches;
    }
  }
  return matches == 1 ? 0 : -1;
}

static int validate_identity(const char *backend, int argc, char **argv) {
  const char *uid = required_env("FAKE_ANCHOR_HOST_UID");
  const char *gid = required_env("FAKE_ANCHOR_HOST_GID");
  char user[64];
  int index;

  if (strcmp(backend, "bubblewrap") == 0) {
    return ((require_pair(argc, argv, "--uid", uid) == 0 &&
             require_pair(argc, argv, "--gid", gid) == 0) ||
            (require_pair(argc, argv, "--uid", "0") == 0 &&
             require_pair(argc, argv, "--gid", "0") == 0))
               ? 0
               : -1;
  }
  if (strcmp(backend, "podman") == 0) {
    if (snprintf(user, sizeof(user), "%s:%s", uid, gid) >= (int)sizeof(user) ||
        require_pair(argc, argv, "--user", user) != 0) {
      return -1;
    }
    for (index = 2; index < argc; ++index) {
      if (strcmp(argv[index], "--userns=keep-id") == 0) {
        return 0;
      }
    }
    return -1;
  }
  if (strcmp(backend, "nspawn") == 0) {
    if (snprintf(user, sizeof(user), "--user=%s", uid) >= (int)sizeof(user)) {
      return -1;
    }
    for (index = 2; index < argc; ++index) {
      if (strcmp(argv[index], user) == 0) {
        return 0;
      }
    }
    return -1;
  }
  return -1;
}

static int read_marker(const char *source, char *marker, size_t marker_size, const char **type_name) {
  struct stat status;
  char *path = NULL;
  const char *read_path = source;
  int fd;
  ssize_t count;

  if (stat(source, &status) != 0) {
    return -1;
  }
  if (S_ISDIR(status.st_mode)) {
    size_t source_length = strlen(source);
    static const char suffix[] = "/marker";

    if (source_length > SIZE_MAX - sizeof(suffix)) {
      errno = ENAMETOOLONG;
      return -1;
    }
    path = malloc(source_length + sizeof(suffix));
    if (path == NULL) {
      return -1;
    }
    memcpy(path, source, source_length);
    memcpy(path + source_length, suffix, sizeof(suffix));
    read_path = path;
    *type_name = "directory";
  } else if (S_ISREG(status.st_mode)) {
    *type_name = "regular";
  } else {
    errno = EINVAL;
    return -1;
  }

  fd = open(read_path, O_RDONLY | O_CLOEXEC);
  free(path);
  if (fd < 0) {
    return -1;
  }
  count = read(fd, marker, marker_size - 1U);
  if (close(fd) != 0 && count >= 0) {
    count = -1;
  }
  if (count < 0) {
    return -1;
  }
  marker[count] = '\0';
  marker[strcspn(marker, "\r\n")] = '\0';
  return 0;
}

static int count_exact_argument(int argc, char **argv, const char *argument) {
  int index;
  int count = 0;

  for (index = 2; index < argc; ++index) {
    if (strcmp(argv[index], argument) == 0) {
      ++count;
    }
  }
  return count;
}

static int count_nspawn_bind_arguments(int argc, char **argv) {
  static const char bind_prefix[] = "--bind=";
  static const char bind_ro_prefix[] = "--bind-ro=";
  int index;
  int count = 0;

  for (index = 2; index < argc; ++index) {
    if (strncmp(argv[index], bind_prefix, sizeof(bind_prefix) - 1U) == 0 ||
        strncmp(argv[index], bind_ro_prefix, sizeof(bind_ro_prefix) - 1U) == 0) {
      ++count;
    }
  }
  return count;
}

static int manifest_unit_argv_is_complete(const char *backend, int argc, char **argv) {
  int index;

  for (index = 2; index < argc; ++index) {
    if (argument_contains_source_token(argv[index]) || strstr(argv[index], "/optional") != NULL) {
      return -1;
    }
  }
  if (strcmp(backend, "bubblewrap") == 0) {
    return count_exact_argument(argc, argv, "--ro-bind-try") == 0 &&
                   count_exact_argument(argc, argv, "--ro-bind") == 1
               ? 0
               : -1;
  }
  if (strcmp(backend, "podman") == 0) {
    return count_exact_argument(argc, argv, "--volume") == 1 ? 0 : -1;
  }
  if (strcmp(backend, "nspawn") == 0) {
    return count_nspawn_bind_arguments(argc, argv) == 1 ? 0 : -1;
  }
  return -1;
}

static int run_manifest_unit(const char *backend, int argc, char **argv, const char *source) {
  char marker[256];
  const char *type_name = NULL;

  if (manifest_unit_argv_is_complete(backend, argc, argv) != 0 ||
      read_marker(source, marker, sizeof(marker), &type_name) != 0 ||
      strcmp(type_name, "regular") != 0 || strcmp(marker, "anchored") != 0) {
    return -1;
  }
  return 0;
}

static int write_result(const char *path, const char *backend, const char *source,
                        const char *marker, const char *type_name) {
  FILE *stream = fopen(path, "w");

  if (stream == NULL) {
    return -1;
  }
  if (fprintf(stream, "backend=%s\nsource=%s\nobserved=%s\ntype=%s\n", backend, source,
              marker, type_name) < 0) {
    (void)fclose(stream);
    return -1;
  }
  return fclose(stream);
}

static int overwrite_nested_marker(const char *source) {
  size_t length = strlen(source);
  static const char suffix[] = "/marker";
  char *path;
  int result;

  if (length > SIZE_MAX - sizeof(suffix)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  path = malloc(length + sizeof(suffix));
  if (path == NULL) {
    return -1;
  }
  memcpy(path, source, length);
  memcpy(path + length, suffix, sizeof(suffix));
  result = write_text_file(path, "modified\n");
  free(path);
  return result;
}

static void child_main(const char *backend, const char *source) {
  const char *forked = required_env("FAKE_ANCHOR_FORKED");
  const char *release = required_env("FAKE_ANCHOR_RELEASE");
  const char *result = required_env("FAKE_ANCHOR_RESULT");
  char marker[256];
  const char *type_name = NULL;

  if (close_extra_fds() != 0 || write_text_file(forked, "FORKED_AND_FDS_CLOSED\n") != 0 ||
      wait_for_file(release, 3000U) != 0 ||
      read_marker(source, marker, sizeof(marker), &type_name) != 0 ||
      write_result(result, backend, source, marker, type_name) != 0) {
    _exit(70);
  }
  _exit(0);
}

int main(int argc, char **argv) {
  const char *backend;
  const char *destination;
  const char *original;
  const char *victim;
  const char *forked;
  const char *release;
  const char *held;
  char *source;
  pid_t child;
  int status;

  if (argc < 3) {
    fail("usage: fake-anchor-runtime BACKEND BACKEND_ARGV...");
  }
  backend = argv[1];
  if (getenv("OCSB_MUTATION_BACKEND_SENTINEL") != NULL) {
    if (strcmp(backend, "bubblewrap") != 0 || run_mutation_backend_sentinel(argc, argv) != 0) {
      fail("workspace mutation backend sentinel failed");
    }
    return 0;
  }
  destination = required_env("FAKE_ANCHOR_DESTINATION");

  if (validate_identity(backend, argc, argv) != 0) {
    fail("backend identity flags differ from the launcher contract");
  }
  if (validate_backend_sources(backend, argc, argv) != 0) {
    fail("backend mount or rootfs source is not a complete private runtime anchor");
  }
  source = find_source(backend, argc, argv, destination);
  if (source == NULL) {
    fail("could not find the declared mount destination in backend argv");
  }
  if (strncmp(source, "/proc/self/fd/", strlen("/proc/self/fd/")) == 0) {
    free(source);
    fail("backend received forbidden /proc/self/fd source");
  }
  if (getenv("FAKE_ANCHOR_MANIFEST_UNIT") != NULL) {
    if (run_manifest_unit(backend, argc, argv, source) != 0) {
      free(source);
      fail("optional manifest unit reached a partial backend argv or unreadable required source");
    }
    free(source);
    return 0;
  }
  if (getenv("FAKE_ANCHOR_NESTED_VICTIM") != NULL) {
    if (overwrite_nested_marker(source) != 0) {
      free(source);
      fail("could not write through nested workspace source");
    }
    free(source);
    return 0;
  }

  original = required_env("FAKE_ANCHOR_ORIGINAL");
  victim = required_env("FAKE_ANCHOR_VICTIM");
  forked = required_env("FAKE_ANCHOR_FORKED");
  release = required_env("FAKE_ANCHOR_RELEASE");
  held = required_env("FAKE_ANCHOR_HELD");

  child = fork();
  if (child < 0) {
    free(source);
    fail("fork failed");
  }
  if (child == 0) {
    child_main(backend, source);
  }

  if (wait_for_file(forked, 3000U) != 0 || rename(original, held) != 0 ||
      symlink(victim, original) != 0 || write_text_file(release, "RELEASE\n") != 0) {
    (void)kill(child, SIGTERM);
    (void)waitpid(child, NULL, 0);
    free(source);
    fail("post-open swap coordination failed");
  }
  free(source);
  if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fail("child did not read its backend source");
  }
  return 0;
}
