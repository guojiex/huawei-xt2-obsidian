#include <node_api.h>
#include <git2.h>

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_ARGUMENT_BYTES 8192
#define OPENHARMONY_SYSTEM_CA_FILE "/etc/ssl/certs/cacert.pem"

typedef struct {
  unsigned int total_objects;
  unsigned int indexed_objects;
  unsigned int received_objects;
  unsigned int local_objects;
  unsigned int total_deltas;
  unsigned int indexed_deltas;
  size_t received_bytes;
} progress_event_t;

typedef struct {
  napi_env env;
  napi_deferred deferred;
  napi_async_work async_work;
  char *url;
  char *target_path;
  char *branch;
  char *username;
  char *password;
  char *ca_file;
  napi_threadsafe_function progress_function;
  int result_code;
  char *error_message;
} clone_work_t;

typedef enum {
  PROPERTY_READ_ERROR = -1,
  PROPERTY_MISSING = 0,
  PROPERTY_PRESENT = 1,
} property_status_t;

static pthread_mutex_t g_clone_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static int g_init_result = -1;

static void initialize_libgit2(void) { g_init_result = git_libgit2_init(); }

static bool ensure_libgit2_initialized(void) {
  return pthread_once(&g_init_once, initialize_libgit2) == 0 && g_init_result >= 0;
}

static bool set_progress_number(napi_env env, napi_value object, const char *name,
                                double number) {
  napi_value value;
  return napi_create_double(env, number, &value) == napi_ok &&
         napi_set_named_property(env, object, name, value) == napi_ok;
}

static void call_progress_on_js_thread(napi_env env, napi_value callback,
                                       void *context, void *data) {
  (void)context;
  progress_event_t *event = (progress_event_t *)data;
  if (event == NULL) {
    return;
  }
  if (env != NULL && callback != NULL) {
    napi_value global;
    napi_value progress;
    if (napi_get_global(env, &global) == napi_ok &&
        napi_create_object(env, &progress) == napi_ok &&
        set_progress_number(env, progress, "totalObjects", event->total_objects) &&
        set_progress_number(env, progress, "indexedObjects", event->indexed_objects) &&
        set_progress_number(env, progress, "receivedObjects", event->received_objects) &&
        set_progress_number(env, progress, "localObjects", event->local_objects) &&
        set_progress_number(env, progress, "totalDeltas", event->total_deltas) &&
        set_progress_number(env, progress, "indexedDeltas", event->indexed_deltas) &&
        set_progress_number(env, progress, "receivedBytes", (double)event->received_bytes)) {
      (void)napi_call_function(env, global, callback, 1, &progress, NULL);
    }
  }
  free(event);
}

static int report_transfer_progress(const git_indexer_progress *stats, void *payload) {
  clone_work_t *work = (clone_work_t *)payload;
  if (work == NULL || work->progress_function == NULL || stats == NULL) {
    return 0;
  }

  progress_event_t *event = (progress_event_t *)malloc(sizeof(*event));
  if (event == NULL) {
    return 0;
  }
  event->total_objects = stats->total_objects;
  event->indexed_objects = stats->indexed_objects;
  event->received_objects = stats->received_objects;
  event->local_objects = stats->local_objects;
  event->total_deltas = stats->total_deltas;
  event->indexed_deltas = stats->indexed_deltas;
  event->received_bytes = stats->received_bytes;

  if (napi_call_threadsafe_function(work->progress_function, event,
                                    napi_tsfn_nonblocking) != napi_ok) {
    free(event);
  }
  return 0;
}

static void capture_clone_error(clone_work_t *work, int result_code) {
  const git_error *error = git_error_last();
  const char *message = error != NULL && error->message != NULL
                            ? error->message
                            : "no libgit2 error detail";
  size_t length = strlen(message);
  work->error_message = (char *)malloc(length + 1);
  if (work->error_message != NULL) {
    memcpy(work->error_message, message, length + 1);
  }
  work->result_code = result_code;
}

static napi_value throw_type_error(napi_env env, const char *message) {
  napi_throw_type_error(env, NULL, message);
  return NULL;
}

static property_status_t read_string_property(napi_env env, napi_value object,
                                              const char *name, char **output) {
  bool has_property = false;
  napi_value value;
  napi_valuetype type;
  size_t length = 0;

  *output = NULL;
  if (napi_has_named_property(env, object, name, &has_property) != napi_ok) {
    return PROPERTY_READ_ERROR;
  }
  if (!has_property) {
    return PROPERTY_MISSING;
  }
  if (napi_get_named_property(env, object, name, &value) != napi_ok ||
      napi_typeof(env, value, &type) != napi_ok) {
    return PROPERTY_READ_ERROR;
  }
  if (type != napi_string ||
      napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok ||
      length > MAX_ARGUMENT_BYTES) {
    return PROPERTY_READ_ERROR;
  }

  char *text = (char *)malloc(length + 1);
  if (text == NULL) {
    return PROPERTY_READ_ERROR;
  }
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, text, length + 1, &copied) != napi_ok ||
      copied != length) {
    free(text);
    return PROPERTY_READ_ERROR;
  }
  *output = text;
  return PROPERTY_PRESENT;
}

static bool has_parent_segment(const char *path) {
  const char *segment = path;
  for (const char *cursor = path;; ++cursor) {
    if (*cursor == '/' || *cursor == '\0') {
      if ((cursor - segment) == 2 && segment[0] == '.' && segment[1] == '.') {
        return true;
      }
      if (*cursor == '\0') {
        return false;
      }
      segment = cursor + 1;
    }
  }
}

static bool url_has_embedded_credentials(const char *url) {
  const char *scheme = strstr(url, "://");
  if (scheme == NULL) {
    return true;
  }
  const char *authority = scheme + 3;
  const char *authority_end = strpbrk(authority, "/?#");
  if (authority_end == NULL) {
    authority_end = url + strlen(url);
  }
  return memchr(authority, '@', (size_t)(authority_end - authority)) != NULL;
}

static int acquire_credentials(git_credential **out, const char *url,
                               const char *username_from_url,
                               unsigned int allowed_types, void *payload) {
  (void)url;
  (void)username_from_url;
  clone_work_t *work = (clone_work_t *)payload;
  if (work == NULL || work->username == NULL || work->password == NULL ||
      (allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT) == 0) {
    return GIT_PASSTHROUGH;
  }
  return git_credential_userpass_plaintext_new(out, work->username, work->password);
}

static void execute_clone(napi_env env, void *data) {
  (void)env;
  clone_work_t *work = (clone_work_t *)data;
  if (!ensure_libgit2_initialized()) {
    work->result_code = -1;
    return;
  }

  pthread_mutex_lock(&g_clone_mutex);
  const char *ca_file = work->ca_file != NULL
                            ? work->ca_file
                            : OPENHARMONY_SYSTEM_CA_FILE;
  if (strncmp(work->url, "https://", 8) == 0 &&
      git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, ca_file, NULL) < 0) {
    capture_clone_error(work, -2);
    pthread_mutex_unlock(&g_clone_mutex);
    return;
  }

  git_clone_options options;
  if (git_clone_options_init(&options, GIT_CLONE_OPTIONS_VERSION) < 0) {
    work->result_code = -4;
    pthread_mutex_unlock(&g_clone_mutex);
    return;
  }
  options.checkout_branch = work->branch;
  options.fetch_opts.callbacks.credentials = acquire_credentials;
  options.fetch_opts.callbacks.transfer_progress = report_transfer_progress;
  options.fetch_opts.callbacks.payload = work;

  git_repository *repository = NULL;
  work->result_code = git_clone(&repository, work->url, work->target_path, &options);
  if (work->result_code < 0) {
    capture_clone_error(work, work->result_code);
  }
  if (repository != NULL) {
    git_repository_free(repository);
  }
  pthread_mutex_unlock(&g_clone_mutex);
}

static void free_clone_work(clone_work_t *work) {
  free(work->url);
  free(work->target_path);
  free(work->branch);
  free(work->username);
  free(work->password);
  free(work->ca_file);
  free(work->error_message);
  free(work);
}

static void release_progress_function(clone_work_t *work) {
  if (work->progress_function != NULL) {
    (void)napi_release_threadsafe_function(work->progress_function, napi_tsfn_release);
    work->progress_function = NULL;
  }
}

static void complete_clone(napi_env env, napi_status status, void *data) {
  clone_work_t *work = (clone_work_t *)data;
  napi_value result;
  if (status == napi_ok && work->result_code == 0 &&
      napi_create_string_utf8(env, work->target_path, NAPI_AUTO_LENGTH, &result) == napi_ok) {
    napi_resolve_deferred(env, work->deferred, result);
  } else {
    napi_value message;
    napi_value error;
    char text[1024];
    (void)snprintf(text, sizeof(text), "libgit2 clone failed (code %d): %s",
                   status == napi_ok ? work->result_code : -3,
                   work->error_message != NULL ? work->error_message : "unknown error");
    if (napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message) == napi_ok &&
        napi_create_error(env, NULL, message, &error) == napi_ok) {
      napi_reject_deferred(env, work->deferred, error);
    }
  }
  release_progress_function(work);
  napi_delete_async_work(env, work->async_work);
  free_clone_work(work);
}

static napi_value get_version(napi_env env, napi_callback_info info) {
  (void)info;
  if (!ensure_libgit2_initialized()) {
    return throw_type_error(env, "libgit2 initialization failed");
  }
  int major = 0;
  int minor = 0;
  int revision = 0;
  git_libgit2_version(&major, &minor, &revision);
  char version[32];
  (void)snprintf(version, sizeof(version), "%d.%d.%d", major, minor, revision);
  napi_value result;
  if (napi_create_string_utf8(env, version, NAPI_AUTO_LENGTH, &result) != napi_ok) {
    return throw_type_error(env, "could not read libgit2 version");
  }
  return result;
}

static napi_value get_features(napi_env env, napi_callback_info info) {
  (void)info;
  if (!ensure_libgit2_initialized()) {
    return throw_type_error(env, "libgit2 initialization failed");
  }
  int features = git_libgit2_features();
  napi_value result;
  napi_value value;
  if (napi_create_object(env, &result) != napi_ok ||
      napi_get_boolean(env, (features & GIT_FEATURE_THREADS) != 0, &value) != napi_ok ||
      napi_set_named_property(env, result, "threads", value) != napi_ok ||
      napi_get_boolean(env, (features & GIT_FEATURE_HTTPS) != 0, &value) != napi_ok ||
      napi_set_named_property(env, result, "https", value) != napi_ok ||
      napi_get_boolean(env, (features & GIT_FEATURE_SSH) != 0, &value) != napi_ok ||
      napi_set_named_property(env, result, "ssh", value) != napi_ok) {
    return throw_type_error(env, "could not read libgit2 features");
  }
  return result;
}

static napi_value clone_async(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_value resource_name;
  napi_value promise;
  napi_value progress_callback = NULL;
  clone_work_t *work;
  bool progress_enabled = false;
  bool has_progress_callback = false;
  property_status_t url_status;
  property_status_t target_status;
  property_status_t branch_status;
  property_status_t username_status;
  property_status_t password_status;
  property_status_t ca_status;

  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 1) {
    return throw_type_error(env, "clone expects one options object");
  }
  napi_valuetype options_type;
  if (napi_typeof(env, argv[0], &options_type) != napi_ok || options_type != napi_object) {
    return throw_type_error(env, "clone options must be an object");
  }

  work = (clone_work_t *)calloc(1, sizeof(*work));
  if (work == NULL) {
    return throw_type_error(env, "could not allocate clone request");
  }
  work->env = env;
  url_status = read_string_property(env, argv[0], "url", &work->url);
  target_status = read_string_property(env, argv[0], "targetPath", &work->target_path);
  branch_status = read_string_property(env, argv[0], "branch", &work->branch);
  username_status = read_string_property(env, argv[0], "username", &work->username);
  password_status = read_string_property(env, argv[0], "password", &work->password);
  ca_status = read_string_property(env, argv[0], "caFile", &work->ca_file);
  if (napi_has_named_property(env, argv[0], "onProgress", &has_progress_callback) != napi_ok) {
    free_clone_work(work);
    return throw_type_error(env, "could not read onProgress callback");
  }
  if (has_progress_callback) {
    napi_valuetype progress_type;
    if (napi_get_named_property(env, argv[0], "onProgress", &progress_callback) != napi_ok ||
        napi_typeof(env, progress_callback, &progress_type) != napi_ok ||
        (progress_type != napi_undefined && progress_type != napi_function)) {
      free_clone_work(work);
      return throw_type_error(env, "onProgress must be a function");
    }
    progress_enabled = progress_type == napi_function;
  }

  if (url_status == PROPERTY_READ_ERROR || target_status == PROPERTY_READ_ERROR ||
      branch_status == PROPERTY_READ_ERROR || username_status == PROPERTY_READ_ERROR ||
      password_status == PROPERTY_READ_ERROR || ca_status == PROPERTY_READ_ERROR) {
    free_clone_work(work);
    return throw_type_error(env, "clone option values must be strings no longer than 8192 bytes");
  }
  if (url_status != PROPERTY_PRESENT || target_status != PROPERTY_PRESENT ||
      (branch_status == PROPERTY_PRESENT && work->branch[0] == '\0') ||
      (username_status == PROPERTY_PRESENT) != (password_status == PROPERTY_PRESENT) ||
      (username_status == PROPERTY_PRESENT &&
       (work->username[0] == '\0' || work->password[0] == '\0'))) {
    free_clone_work(work);
    return throw_type_error(env, "clone options require url and targetPath; credentials must be paired");
  }
  if (strncmp(work->url, "https://", 8) != 0 && strncmp(work->url, "http://", 7) != 0) {
    free_clone_work(work);
    return throw_type_error(env, "only HTTP and HTTPS remotes are supported");
  }
  if (url_has_embedded_credentials(work->url)) {
    free_clone_work(work);
    return throw_type_error(env, "credentials must be passed separately from the remote URL");
  }
  if (work->target_path[0] != '/' || has_parent_segment(work->target_path)) {
    free_clone_work(work);
    return throw_type_error(env, "targetPath must be an absolute path without '..'");
  }
  if (strncmp(work->url, "https://", 8) == 0 && ca_status == PROPERTY_PRESENT &&
      (work->ca_file[0] != '/' || access(work->ca_file, R_OK) != 0)) {
    free_clone_work(work);
    return throw_type_error(env, "caFile override must be an absolute readable path");
  }
  struct stat target_stat;
  if (lstat(work->target_path, &target_stat) == 0) {
    free_clone_work(work);
    return throw_type_error(env, "targetPath must not already exist");
  }
  if (errno != ENOENT) {
    free_clone_work(work);
    return throw_type_error(env, "could not inspect targetPath");
  }

  if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
      napi_create_string_utf8(env, "libgit2.clone", NAPI_AUTO_LENGTH, &resource_name) != napi_ok) {
    free_clone_work(work);
    return throw_type_error(env, "could not create async clone work");
  }
  if (progress_enabled &&
      napi_create_threadsafe_function(env, progress_callback, NULL, resource_name,
                                      32, 1, NULL, NULL, NULL,
                                      call_progress_on_js_thread,
                                      &work->progress_function) != napi_ok) {
    free_clone_work(work);
    return throw_type_error(env, "could not create progress callback");
  }
  if (napi_create_async_work(env, NULL, resource_name, execute_clone, complete_clone,
                             work, &work->async_work) != napi_ok) {
    release_progress_function(work);
    free_clone_work(work);
    return throw_type_error(env, "could not create async clone work");
  }
  if (napi_queue_async_work(env, work->async_work) != napi_ok) {
    napi_delete_async_work(env, work->async_work);
    release_progress_function(work);
    free_clone_work(work);
    return throw_type_error(env, "could not queue async clone work");
  }
  return promise;
}

static napi_value register_module(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"getVersion", NULL, get_version, NULL, NULL, NULL, napi_default, NULL},
      {"getFeatures", NULL, get_features, NULL, NULL, NULL, napi_default, NULL},
      {"clone", NULL, clone_async, NULL, NULL, NULL, napi_default, NULL},
  };
  if (napi_define_properties(env, exports,
                             sizeof(properties) / sizeof(properties[0]),
                             properties) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(libgit2_napi, register_module)
