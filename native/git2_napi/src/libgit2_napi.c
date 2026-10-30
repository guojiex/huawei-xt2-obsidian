#include <node_api.h>
#include <git2.h>
#include <git2/diff.h>
#include <git2/graph.h>

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
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
  char *bearer_token;
  char *ca_file;
  napi_threadsafe_function progress_function;
  int result_code;
  char *error_message;
} clone_work_t;

typedef struct {
  napi_env env;
  napi_deferred deferred;
  napi_async_work async_work;
  char *operation;
  char *repository_path;
  char *username;
  char *password;
  char *bearer_token;
  char *ca_file;
  char *message;
  char *author_name;
  char *author_email;
  char *result_text;
  char *error_message;
  char *push_status;
  bool remote_xt2_exists;
  napi_threadsafe_function progress_function;
  int result_code;
} git_operation_work_t;

typedef enum {
  PROPERTY_READ_ERROR = -1,
  PROPERTY_MISSING = 0,
  PROPERTY_PRESENT = 1,
} property_status_t;

static pthread_mutex_t g_clone_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static int g_init_result = -1;

static bool url_has_embedded_credentials(const char *url);
static napi_value throw_type_error(napi_env env, const char *message);
static property_status_t read_string_property(napi_env env, napi_value object,
                                             const char *name, char **output);
static bool has_parent_segment(const char *path);
static bool is_trash_path(const char *path);
static int stage_all(git_repository *repository);
static int create_commit(git_repository *repository, git_operation_work_t *work);

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

static void call_operation_progress_on_js_thread(napi_env env, napi_value callback,
                                                 void *context, void *data) {
  call_progress_on_js_thread(env, callback, context, data);
}

static int report_operation_progress(const git_indexer_progress *stats, void *payload) {
  git_operation_work_t *work = (git_operation_work_t *)payload;
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

static int acquire_operation_credentials(git_credential **out, const char *url,
                                         const char *username_from_url,
                                         unsigned int allowed_types, void *payload) {
  (void)url;
  (void)username_from_url;
  git_operation_work_t *work = (git_operation_work_t *)payload;
  if (work == NULL || work->username == NULL || work->password == NULL ||
      (allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT) == 0) {
    return GIT_PASSTHROUGH;
  }
  return git_credential_userpass_plaintext_new(out, work->username, work->password);
}

static int record_push_update(const char *refname, const char *status, void *payload) {
  (void)refname;
  git_operation_work_t *work = (git_operation_work_t *)payload;
  if (work == NULL || status == NULL || status[0] == '\0') {
    return 0;
  }
  const size_t length = strlen(status);
  char *copy = (char *)malloc(length + 1);
  if (copy != NULL) {
    memcpy(copy, status, length + 1);
    free(work->push_status);
    work->push_status = copy;
  }
  return 0;
}

static void capture_operation_error(git_operation_work_t *work, int result_code) {
  const git_error *error = git_error_last();
  const char *message = error != NULL && error->message != NULL
                            ? error->message
                            : "no libgit2 error detail";
  const size_t length = strlen(message);
  work->error_message = (char *)malloc(length + 1);
  if (work->error_message != NULL) {
    memcpy(work->error_message, message, length + 1);
  }
  work->result_code = result_code;
}

static bool is_https_remote(const char *url) {
  return url != NULL && strncmp(url, "https://", 8) == 0;
}

static int configure_remote_auth(git_operation_work_t *work, const char *url,
                                 git_remote_callbacks *callbacks,
                                 git_strarray *headers, char **authorization_header) {
  callbacks->credentials = acquire_operation_credentials;
  callbacks->transfer_progress = report_operation_progress;
  callbacks->push_update_reference = record_push_update;
  callbacks->payload = work;
  headers->strings = NULL;
  headers->count = 0;
  *authorization_header = NULL;

  if (url_has_embedded_credentials(url)) {
    return -1;
  }
  if (work->bearer_token != NULL) {
    const char prefix[] = "Authorization: Bearer ";
    const size_t token_length = strlen(work->bearer_token);
    const size_t prefix_length = sizeof(prefix) - 1;
    *authorization_header = (char *)malloc(prefix_length + token_length + 1);
    if (*authorization_header == NULL) {
      return -1;
    }
    memcpy(*authorization_header, prefix, prefix_length);
    memcpy(*authorization_header + prefix_length, work->bearer_token, token_length + 1);
    headers->strings = authorization_header;
    headers->count = 1;
  }
  return 0;
}

static int fetch_xt2(git_remote *remote, git_operation_work_t *work,
                     const git_remote_callbacks *callbacks,
                     const git_strarray *headers) {
  git_remote_connect_options connect_options;
  if (git_remote_connect_options_init(&connect_options,
                                     GIT_REMOTE_CONNECT_OPTIONS_VERSION) < 0) {
    return -1;
  }
  connect_options.callbacks = *callbacks;
  connect_options.custom_headers = *headers;
  if (git_remote_connect_ext(remote, GIT_DIRECTION_FETCH, &connect_options) < 0) {
    return -1;
  }

  const git_remote_head **heads = NULL;
  size_t head_count = 0;
  const int list_result = git_remote_ls(&heads, &head_count, remote);
  bool xt2_exists = false;
  if (list_result == 0) {
    for (size_t i = 0; i < head_count; i++) {
      if (heads[i] != NULL && heads[i]->name != NULL &&
          strcmp(heads[i]->name, "refs/heads/xt2") == 0) {
        xt2_exists = true;
        break;
      }
    }
  }
  git_remote_disconnect(remote);
  if (list_result < 0) {
    return list_result;
  }
  if (!xt2_exists) {
    work->remote_xt2_exists = false;
    work->result_text = strdup("missing");
    return work->result_text != NULL ? 0 : -1;
  }
  work->remote_xt2_exists = true;

  git_fetch_options fetch_options;
  if (git_fetch_options_init(&fetch_options, GIT_FETCH_OPTIONS_VERSION) < 0) {
    return -1;
  }
  fetch_options.callbacks = *callbacks;
  fetch_options.custom_headers = *headers;
  char *refspec_text = "+refs/heads/xt2:refs/remotes/origin/xt2";
  git_strarray refspecs = { &refspec_text, 1 };
  if (git_remote_fetch(remote, &refspecs, &fetch_options, "fetch xt2") < 0) {
    return -1;
  }
  work->result_text = strdup("fetched");
  return work->result_text != NULL ? 0 : -1;
}

static int push_xt2(git_repository *repository, git_remote *remote,
                    git_operation_work_t *work,
                    const git_remote_callbacks *callbacks,
                    const git_strarray *headers) {
  git_reference *head = NULL;
  git_reference *tracking = NULL;
  git_oid local_oid;
  git_oid remote_oid;
  const char *local_refname = NULL;
  int result = 0;

  if (git_repository_head(&head, repository) < 0 ||
      git_reference_name(head) == NULL ||
      strncmp(git_reference_name(head), "refs/heads/", 11) != 0 ||
      git_reference_name_to_id(&local_oid, repository, git_reference_name(head)) < 0) {
    result = -1;
    goto cleanup;
  }
  local_refname = git_reference_name(head);

  git_status_options status_options;
  git_status_list *status = NULL;
  if (git_status_options_init(&status_options, GIT_STATUS_OPTIONS_VERSION) < 0 ||
      git_status_list_new(&status, repository, &status_options) < 0) {
    git_status_list_free(status);
    result = -1;
    goto cleanup;
  }
  for (size_t i = 0; i < git_status_list_entrycount(status); i++) {
    const git_status_entry *entry = git_status_byindex(status, i);
    const char *path = NULL;
    if (entry != NULL && entry->index_to_workdir != NULL) {
      path = entry->index_to_workdir->new_file.path != NULL
                 ? entry->index_to_workdir->new_file.path
                 : entry->index_to_workdir->old_file.path;
    }
    if (path == NULL && entry != NULL && entry->head_to_index != NULL) {
      path = entry->head_to_index->new_file.path != NULL
                 ? entry->head_to_index->new_file.path
                 : entry->head_to_index->old_file.path;
    }
    if (!is_trash_path(path)) {
      git_status_list_free(status);
      work->error_message = strdup("工作区还有未提交更改，请先暂存并提交");
      result = -1;
      goto cleanup;
    }
  }
  git_status_list_free(status);

  if (work->remote_xt2_exists) {
    int tracking_result = git_reference_lookup(&tracking, repository,
                                               "refs/remotes/origin/xt2");
    if (tracking_result < 0 || git_reference_target(tracking) == NULL) {
      result = tracking_result < 0 ? tracking_result : -1;
      goto cleanup;
    }
    remote_oid = *git_reference_target(tracking);
    if (!git_oid_equal(&local_oid, &remote_oid) &&
        git_graph_descendant_of(repository, &local_oid, &remote_oid) != 1) {
      work->error_message = strdup("远端 xt2 已变化且不包含本地提交；拒绝覆盖，请在 PC 端解决冲突");
      result = -1;
      goto cleanup;
    }
  }

  git_push_options push_options;
  if (git_push_options_init(&push_options, GIT_PUSH_OPTIONS_VERSION) < 0) {
    result = -1;
    goto cleanup;
  }
  push_options.callbacks = *callbacks;
  push_options.custom_headers = *headers;
  char *refspec_text = NULL;
  const size_t refname_length = strlen(local_refname);
  const char suffix[] = ":refs/heads/xt2";
  refspec_text = (char *)malloc(refname_length + sizeof(suffix));
  if (refspec_text == NULL) {
    result = -1;
    goto cleanup;
  }
  memcpy(refspec_text, local_refname, refname_length);
  memcpy(refspec_text + refname_length, suffix, sizeof(suffix));
  git_strarray refspecs = { &refspec_text, 1 };
  const int push_result = git_remote_push(remote, &refspecs, &push_options);
  free(refspec_text);
  if (push_result < 0 || work->push_status != NULL) {
    if (work->push_status != NULL) {
      work->error_message = strdup(work->push_status);
    }
    result = -1;
  } else {
    git_reference_free(tracking);
    tracking = NULL;
    if (git_reference_create(&tracking, repository, "refs/remotes/origin/xt2",
                             &local_oid, 1, "update after push to xt2") < 0) {
      work->error_message = strdup("远端已接收推送，但本地 xt2 跟踪状态未更新；可重试推送");
      result = -1;
      goto cleanup;
    }
    char oid_text[GIT_OID_HEXSZ + 1];
    git_oid_tostr(oid_text, sizeof(oid_text), &local_oid);
    work->result_text = strdup(oid_text);
    if (work->result_text == NULL) {
      result = -1;
    }
  }
cleanup:
  if (result < 0 && work->error_message == NULL) {
    capture_operation_error(work, result);
  }
  git_reference_free(tracking);
  git_reference_free(head);
  return result;
}

static void free_git_operation(git_operation_work_t *work) {
  free(work->operation);
  free(work->repository_path);
  free(work->username);
  free(work->password);
  free(work->bearer_token);
  free(work->ca_file);
  free(work->message);
  free(work->author_name);
  free(work->author_email);
  free(work->result_text);
  free(work->error_message);
  free(work->push_status);
  free(work);
}

static void execute_git_operation(napi_env env, void *data) {
  (void)env;
  git_operation_work_t *work = (git_operation_work_t *)data;
  git_repository *repository = NULL;
  git_remote *remote = NULL;
  char *authorization_header = NULL;
  git_strarray headers = { NULL, 0 };
  int result = -1;

  if (!ensure_libgit2_initialized()) {
    work->result_code = -1;
    return;
  }
  pthread_mutex_lock(&g_clone_mutex);
  if (git_repository_open_ext(&repository, work->repository_path,
                              GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) < 0) {
    capture_operation_error(work, -1);
    goto cleanup;
  }

  if (strcmp(work->operation, "stage") == 0) {
    result = stage_all(repository);
  } else if (strcmp(work->operation, "commit") == 0) {
    result = create_commit(repository, work);
  } else if (strcmp(work->operation, "fetch") == 0 ||
             strcmp(work->operation, "push") == 0) {
    if (git_remote_lookup(&remote, repository, "origin") < 0) {
      result = -1;
      goto operation_failed;
    }
    const char *url = git_remote_url(remote);
    if (url == NULL) {
      work->error_message = strdup("origin remote has no URL");
      result = -1;
      goto operation_failed;
    }
    if (is_https_remote(url)) {
      const char *ca_file = work->ca_file != NULL
                                ? work->ca_file
                                : OPENHARMONY_SYSTEM_CA_FILE;
      if (git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, ca_file, NULL) < 0) {
        result = -1;
        goto operation_failed;
      }
    }
    git_remote_callbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = GIT_REMOTE_CALLBACKS_VERSION;
    if (configure_remote_auth(work, url, &callbacks, &headers,
                              &authorization_header) < 0) {
      work->error_message = strdup("remote URL or authentication options are invalid");
      result = -1;
      goto operation_failed;
    }
    result = fetch_xt2(remote, work, &callbacks, &headers);
    if (result == 0 && strcmp(work->operation, "push") == 0) {
      free(work->result_text);
      work->result_text = NULL;
      result = push_xt2(repository, remote, work, &callbacks, &headers);
    }
  } else {
    work->error_message = strdup("unsupported Git operation");
    result = -1;
  }

operation_failed:
  if (result < 0 && work->error_message == NULL) {
    capture_operation_error(work, result);
  }
  work->result_code = result;

cleanup:
  free(authorization_header);
  git_remote_free(remote);
  git_repository_free(repository);
  pthread_mutex_unlock(&g_clone_mutex);
}

static void complete_git_operation(napi_env env, napi_status status, void *data) {
  git_operation_work_t *work = (git_operation_work_t *)data;
  napi_value value;
  if (status == napi_ok && work->result_code == 0 && work->result_text != NULL &&
      napi_create_string_utf8(env, work->result_text, NAPI_AUTO_LENGTH, &value) == napi_ok) {
    napi_resolve_deferred(env, work->deferred, value);
  } else if (status == napi_ok && work->result_code == 0 &&
             napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &value) == napi_ok) {
    napi_resolve_deferred(env, work->deferred, value);
  } else {
    char text[1024];
    (void)snprintf(text, sizeof(text), "libgit2 %s failed (code %d): %s",
                   work->operation != NULL ? work->operation : "operation",
                   status == napi_ok ? work->result_code : -3,
                   work->error_message != NULL ? work->error_message : "unknown error");
    napi_value message;
    napi_value error;
    if (napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message) == napi_ok &&
        napi_create_error(env, NULL, message, &error) == napi_ok) {
      napi_reject_deferred(env, work->deferred, error);
    }
  }
  if (work->progress_function != NULL) {
    (void)napi_release_threadsafe_function(work->progress_function, napi_tsfn_release);
  }
  napi_delete_async_work(env, work->async_work);
  free_git_operation(work);
}

static napi_value git_action_async(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_value promise;
  napi_value resource_name;
  napi_value progress_callback = NULL;
  bool has_progress_callback = false;
  bool progress_enabled = false;
  property_status_t operation_status;
  property_status_t path_status;
  property_status_t username_status;
  property_status_t password_status;
  property_status_t bearer_status;
  property_status_t ca_status;
  property_status_t message_status;
  property_status_t author_name_status;
  property_status_t author_email_status;

  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 1) {
    return throw_type_error(env, "gitAction expects one options object");
  }
  napi_valuetype options_type;
  if (napi_typeof(env, argv[0], &options_type) != napi_ok || options_type != napi_object) {
    return throw_type_error(env, "gitAction options must be an object");
  }
  git_operation_work_t *work = (git_operation_work_t *)calloc(1, sizeof(*work));
  if (work == NULL) {
    return throw_type_error(env, "could not allocate Git operation");
  }
  work->env = env;
  operation_status = read_string_property(env, argv[0], "operation", &work->operation);
  path_status = read_string_property(env, argv[0], "repositoryPath", &work->repository_path);
  username_status = read_string_property(env, argv[0], "username", &work->username);
  password_status = read_string_property(env, argv[0], "password", &work->password);
  bearer_status = read_string_property(env, argv[0], "bearerToken", &work->bearer_token);
  ca_status = read_string_property(env, argv[0], "caFile", &work->ca_file);
  message_status = read_string_property(env, argv[0], "message", &work->message);
  author_name_status = read_string_property(env, argv[0], "authorName", &work->author_name);
  author_email_status = read_string_property(env, argv[0], "authorEmail", &work->author_email);
  if (napi_has_named_property(env, argv[0], "onProgress", &has_progress_callback) != napi_ok) {
    free_git_operation(work);
    return throw_type_error(env, "could not read onProgress callback");
  }
  if (has_progress_callback) {
    napi_valuetype progress_type;
    if (napi_get_named_property(env, argv[0], "onProgress", &progress_callback) != napi_ok ||
        napi_typeof(env, progress_callback, &progress_type) != napi_ok ||
        (progress_type != napi_undefined && progress_type != napi_function)) {
      free_git_operation(work);
      return throw_type_error(env, "onProgress must be a function");
    }
    progress_enabled = progress_type == napi_function;
  }
  if (operation_status == PROPERTY_READ_ERROR || path_status == PROPERTY_READ_ERROR ||
      username_status == PROPERTY_READ_ERROR || password_status == PROPERTY_READ_ERROR ||
      bearer_status == PROPERTY_READ_ERROR || ca_status == PROPERTY_READ_ERROR ||
      message_status == PROPERTY_READ_ERROR || author_name_status == PROPERTY_READ_ERROR ||
      author_email_status == PROPERTY_READ_ERROR) {
    free_git_operation(work);
    return throw_type_error(env, "Git operation values must be strings no longer than 8192 bytes");
  }
  if (operation_status != PROPERTY_PRESENT || path_status != PROPERTY_PRESENT ||
      work->repository_path[0] != '/' || has_parent_segment(work->repository_path) ||
      (username_status == PROPERTY_PRESENT) != (password_status == PROPERTY_PRESENT) ||
      (username_status == PROPERTY_PRESENT &&
       (work->username[0] == '\0' || work->password[0] == '\0')) ||
      (bearer_status == PROPERTY_PRESENT &&
       (work->bearer_token[0] == '\0' || username_status == PROPERTY_PRESENT)) ||
      (strcmp(work->operation, "stage") != 0 && strcmp(work->operation, "commit") != 0 &&
       strcmp(work->operation, "fetch") != 0 && strcmp(work->operation, "push") != 0)) {
    free_git_operation(work);
    return throw_type_error(env, "invalid Git operation options");
  }
  if (strcmp(work->operation, "commit") == 0 &&
      (message_status != PROPERTY_PRESENT || author_name_status != PROPERTY_PRESENT ||
       author_email_status != PROPERTY_PRESENT)) {
    free_git_operation(work);
    return throw_type_error(env, "commit requires message, authorName and authorEmail");
  }
  if (ca_status == PROPERTY_PRESENT &&
      (work->ca_file[0] != '/' || access(work->ca_file, R_OK) != 0)) {
    free_git_operation(work);
    return throw_type_error(env, "caFile override must be an absolute readable path");
  }
  if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
      napi_create_string_utf8(env, "libgit2.operation", NAPI_AUTO_LENGTH,
                              &resource_name) != napi_ok) {
    free_git_operation(work);
    return throw_type_error(env, "could not create Git operation promise");
  }
  if (progress_enabled &&
      napi_create_threadsafe_function(env, progress_callback, NULL, resource_name,
                                      32, 1, NULL, NULL, NULL,
                                      call_operation_progress_on_js_thread,
                                      &work->progress_function) != napi_ok) {
    free_git_operation(work);
    return throw_type_error(env, "could not create progress callback");
  }
  if (napi_create_async_work(env, NULL, resource_name, execute_git_operation,
                             complete_git_operation, work, &work->async_work) != napi_ok) {
    if (work->progress_function != NULL) {
      (void)napi_release_threadsafe_function(work->progress_function, napi_tsfn_release);
    }
    free_git_operation(work);
    return throw_type_error(env, "could not create async Git operation");
  }
  if (napi_queue_async_work(env, work->async_work) != napi_ok) {
    napi_delete_async_work(env, work->async_work);
    if (work->progress_function != NULL) {
      (void)napi_release_threadsafe_function(work->progress_function, napi_tsfn_release);
    }
    free_git_operation(work);
    return throw_type_error(env, "could not queue async Git operation");
  }
  return promise;
}

static int skip_trash_path(const char *path, const char *matched_pathspec, void *payload) {
  (void)matched_pathspec;
  (void)payload;
  return is_trash_path(path) ? 1 : 0;
}

static int keep_trash_index_entry(const char *path, const char *matched_pathspec,
                                  void *payload) {
  (void)matched_pathspec;
  (void)payload;
  return is_trash_path(path) ? 1 : 0;
}

static int stage_all(git_repository *repository) {
  git_index *index = NULL;
  if (git_repository_index(&index, repository) < 0) {
    return -1;
  }
  int remove_result = git_index_remove_all(index, NULL, keep_trash_index_entry, NULL);
  if (remove_result < 0 && remove_result != GIT_ENOTFOUND) {
    git_index_free(index);
    return remove_result;
  }
  int result = git_index_add_all(index, NULL, GIT_INDEX_ADD_DEFAULT,
                                 skip_trash_path, NULL);
  if (result == 0) {
    result = git_index_write(index);
  }
  git_index_free(index);
  return result;
}

static int create_commit(git_repository *repository, git_operation_work_t *work) {
  git_index *index = NULL;
  git_diff *staged_diff = NULL;
  git_tree *tree = NULL;
  git_tree *parent_tree = NULL;
  git_commit *parent = NULL;
  git_signature *author = NULL;
  git_signature *committer = NULL;
  git_reference *head = NULL;
  git_oid tree_oid;
  git_oid commit_oid;
  int result = -1;

  if (work->message == NULL || work->message[0] == '\0' ||
      work->author_name == NULL || work->author_name[0] == '\0' ||
      work->author_email == NULL || work->author_email[0] == '\0') {
    work->error_message = strdup("提交需要填写提交说明、作者名和邮箱");
    return -1;
  }
  if (git_repository_index(&index, repository) < 0) {
    goto cleanup;
  }
  int head_unborn = git_repository_head_unborn(repository);
  if (head_unborn < 0) {
    goto cleanup;
  }
  if (head_unborn == 0) {
    if (git_repository_head(&head, repository) < 0 ||
        git_reference_target(head) == NULL ||
        git_commit_lookup(&parent, repository, git_reference_target(head)) < 0) {
      goto cleanup;
    }
    if (git_commit_tree(&parent_tree, parent) < 0 || git_tree_id(parent_tree) == NULL) {
      goto cleanup;
    }
  }
  if (git_diff_tree_to_index(&staged_diff, repository, parent_tree, index, NULL) < 0) {
    goto cleanup;
  }
  for (size_t i = 0; i < git_diff_num_deltas(staged_diff); i++) {
    const git_diff_delta *delta = git_diff_get_delta(staged_diff, i);
    if (delta != NULL &&
        (is_trash_path(delta->old_file.path) || is_trash_path(delta->new_file.path))) {
      work->error_message = strdup("暂存区含 .trash 更改，请先取消这些暂存更改");
      goto cleanup;
    }
  }
  if (git_index_write_tree(&tree_oid, index) < 0 ||
      git_tree_lookup(&tree, repository, &tree_oid) < 0) {
    goto cleanup;
  }
  if (head_unborn == 0) {
    if (git_oid_equal(git_tree_id(parent_tree), &tree_oid)) {
      work->error_message = strdup("没有新的已暂存更改");
      goto cleanup;
    }
  }
  if (git_signature_new(&author, work->author_name, work->author_email, time(NULL), 0) < 0 ||
      git_signature_new(&committer, work->author_name, work->author_email, time(NULL), 0) < 0) {
    goto cleanup;
  }
  const git_commit *parents[1];
  size_t parent_count = 0;
  if (parent != NULL) {
    parents[0] = parent;
    parent_count = 1;
  }
  if (git_commit_create(&commit_oid, repository, "HEAD", author, committer, NULL,
                        work->message, tree, parent_count,
                        parent_count > 0 ? parents : NULL) < 0) {
    goto cleanup;
  }
  char oid_text[GIT_OID_HEXSZ + 1];
  git_oid_tostr(oid_text, sizeof(oid_text), &commit_oid);
  work->result_text = strdup(oid_text);
  result = work->result_text != NULL ? 0 : -1;

cleanup:
  if (result < 0 && work->error_message == NULL) {
    capture_operation_error(work, result);
  }
  git_reference_free(head);
  git_diff_free(staged_diff);
  git_signature_free(committer);
  git_signature_free(author);
  git_tree_free(parent_tree);
  git_commit_free(parent);
  git_tree_free(tree);
  git_index_free(index);
  return result;
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

static napi_value throw_git_error(napi_env env, const char *operation) {
  const git_error *git_error = git_error_last();
  const char *detail = git_error != NULL && git_error->message != NULL
                           ? git_error->message
                           : "unknown libgit2 error";
  char text[1024];
  napi_value message;
  napi_value error;
  (void)snprintf(text, sizeof(text), "%s: %s", operation, detail);
  if (napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message) == napi_ok &&
      napi_create_error(env, NULL, message, &error) == napi_ok) {
    (void)napi_throw(env, error);
    return NULL;
  }
  return throw_type_error(env, operation);
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

  char *authorization_header = NULL;
  char *authorization_headers[1];
  if (work->bearer_token != NULL) {
    const char prefix[] = "Authorization: Bearer ";
    size_t token_length = strlen(work->bearer_token);
    size_t prefix_length = sizeof(prefix) - 1;
    authorization_header = (char *)malloc(prefix_length + token_length + 1);
    if (authorization_header == NULL) {
      work->result_code = -5;
      pthread_mutex_unlock(&g_clone_mutex);
      return;
    }
    memcpy(authorization_header, prefix, prefix_length);
    memcpy(authorization_header + prefix_length, work->bearer_token, token_length + 1);
    authorization_headers[0] = authorization_header;
    options.fetch_opts.custom_headers.strings = authorization_headers;
    options.fetch_opts.custom_headers.count = 1;
  }

  git_repository *repository = NULL;
  work->result_code = git_clone(&repository, work->url, work->target_path, &options);
  if (work->result_code < 0) {
    capture_clone_error(work, work->result_code);
  }
  if (repository != NULL) {
    git_repository_free(repository);
  }
  free(authorization_header);
  pthread_mutex_unlock(&g_clone_mutex);
}

static void free_clone_work(clone_work_t *work) {
  free(work->url);
  free(work->target_path);
  free(work->branch);
  free(work->username);
  free(work->password);
  free(work->bearer_token);
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

static bool is_trash_path(const char *path) {
  return path != NULL &&
         (strcmp(path, ".trash") == 0 || strncmp(path, ".trash/", 7) == 0);
}

static napi_value get_repository_state(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_valuetype type;
  size_t path_length = 0;
  char *path = NULL;
  git_repository *repository = NULL;
  git_reference *head = NULL;
  git_status_list *status = NULL;
  napi_value result;
  napi_value branch_value;
  napi_value clean_value;
  napi_value status_count_value;
  napi_value pack_count_value;
  napi_value head_value;
  napi_value ahead_count_value;
  napi_value behind_count_value;
  char pack_directory[MAX_ARGUMENT_BYTES + 32];
  size_t pack_file_count = 0;
  size_t status_count = 0;
  size_t ahead_count = 0;
  size_t behind_count = 0;
  const char *branch = "";
  char head_text[GIT_OID_HEXSZ + 1] = "";
  git_oid head_oid;
  bool clean = false;

  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 1 ||
      napi_typeof(env, argv[0], &type) != napi_ok || type != napi_string ||
      napi_get_value_string_utf8(env, argv[0], NULL, 0, &path_length) != napi_ok ||
      path_length == 0 || path_length > MAX_ARGUMENT_BYTES) {
    return throw_type_error(env, "getRepositoryState expects one absolute repository path");
  }

  path = (char *)malloc(path_length + 1);
  if (path == NULL ||
      napi_get_value_string_utf8(env, argv[0], path, path_length + 1, &path_length) != napi_ok ||
      path[0] != '/') {
    free(path);
    return throw_type_error(env, "repository path must be absolute");
  }

  if (!ensure_libgit2_initialized()) {
    free(path);
    return throw_type_error(env, "libgit2 initialization failed");
  }
  pthread_mutex_lock(&g_clone_mutex);
  if (git_repository_open_ext(&repository, path, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) < 0) {
    git_repository_free(repository);
    pthread_mutex_unlock(&g_clone_mutex);
    free(path);
    return throw_git_error(env, "repository could not be opened");
  }

  if (git_repository_head(&head, repository) == 0) {
    branch = git_reference_shorthand(head);
    if (branch == NULL) {
      branch = "";
    }
  }

  git_status_options status_options;
  if (git_status_options_init(&status_options, GIT_STATUS_OPTIONS_VERSION) < 0) {
    git_repository_free(repository);
    pthread_mutex_unlock(&g_clone_mutex);
    free(path);
    return throw_git_error(env, "repository status options failed");
  }
  status_options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  status_options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED |
                         GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
  if (git_status_list_new(&status, repository, &status_options) < 0) {
    git_repository_free(repository);
    pthread_mutex_unlock(&g_clone_mutex);
    free(path);
    return throw_git_error(env, "repository status failed");
  }
  for (size_t i = 0; i < git_status_list_entrycount(status); i++) {
    const git_status_entry *entry = git_status_byindex(status, i);
    const char *old_path = NULL;
    const char *new_path = NULL;
    if (entry != NULL && entry->head_to_index != NULL) {
      old_path = entry->head_to_index->old_file.path;
      new_path = entry->head_to_index->new_file.path;
    }
    if (entry != NULL && entry->index_to_workdir != NULL) {
      if (old_path == NULL) old_path = entry->index_to_workdir->old_file.path;
      if (new_path == NULL) new_path = entry->index_to_workdir->new_file.path;
    }
    if (!is_trash_path(old_path) && !is_trash_path(new_path)) {
      status_count++;
    }
  }
  clean = status_count == 0;

  if (git_reference_name_to_id(&head_oid, repository, "HEAD") == 0) {
    git_oid_tostr(head_text, sizeof(head_text), &head_oid);
    git_reference *remote_tracking = NULL;
    if (git_reference_lookup(&remote_tracking, repository,
                             "refs/remotes/origin/xt2") == 0 &&
        git_reference_target(remote_tracking) != NULL) {
      (void)git_graph_ahead_behind(&ahead_count, &behind_count, repository,
                                   &head_oid, git_reference_target(remote_tracking));
    }
    git_reference_free(remote_tracking);
  }

  const char *git_directory = git_repository_path(repository);
  if (git_directory != NULL &&
      snprintf(pack_directory, sizeof(pack_directory), "%sobjects/pack", git_directory) > 0) {
    DIR *directory = opendir(pack_directory);
    if (directory != NULL) {
      struct dirent *entry;
      while ((entry = readdir(directory)) != NULL) {
        size_t name_length = strlen(entry->d_name);
        if (name_length > 5 && strcmp(entry->d_name + name_length - 5, ".pack") == 0) {
          pack_file_count++;
        }
      }
      closedir(directory);
    }
  }

  if (napi_create_object(env, &result) != napi_ok ||
      napi_create_string_utf8(env, branch, NAPI_AUTO_LENGTH, &branch_value) != napi_ok ||
      napi_set_named_property(env, result, "branch", branch_value) != napi_ok ||
      napi_create_string_utf8(env, head_text, NAPI_AUTO_LENGTH, &head_value) != napi_ok ||
      napi_set_named_property(env, result, "head", head_value) != napi_ok ||
      napi_get_boolean(env, clean, &clean_value) != napi_ok ||
      napi_set_named_property(env, result, "clean", clean_value) != napi_ok ||
      napi_create_double(env, (double)status_count, &status_count_value) != napi_ok ||
      napi_set_named_property(env, result, "statusEntryCount", status_count_value) != napi_ok ||
      napi_create_double(env, (double)pack_file_count, &pack_count_value) != napi_ok ||
      napi_set_named_property(env, result, "packFileCount", pack_count_value) != napi_ok ||
      napi_create_double(env, (double)ahead_count, &ahead_count_value) != napi_ok ||
      napi_set_named_property(env, result, "aheadCount", ahead_count_value) != napi_ok ||
      napi_create_double(env, (double)behind_count, &behind_count_value) != napi_ok ||
      napi_set_named_property(env, result, "behindCount", behind_count_value) != napi_ok) {
    git_status_list_free(status);
    git_reference_free(head);
    git_repository_free(repository);
    pthread_mutex_unlock(&g_clone_mutex);
    free(path);
    return throw_type_error(env, "could not read repository state");
  }

  git_status_list_free(status);
  git_reference_free(head);
  git_repository_free(repository);
  pthread_mutex_unlock(&g_clone_mutex);
  free(path);
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
  property_status_t bearer_status;
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
  bearer_status = read_string_property(env, argv[0], "bearerToken", &work->bearer_token);
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
      password_status == PROPERTY_READ_ERROR || bearer_status == PROPERTY_READ_ERROR ||
      ca_status == PROPERTY_READ_ERROR) {
    free_clone_work(work);
    return throw_type_error(env, "clone option values must be strings no longer than 8192 bytes");
  }
  if (url_status != PROPERTY_PRESENT || target_status != PROPERTY_PRESENT ||
      (branch_status == PROPERTY_PRESENT && work->branch[0] == '\0') ||
      (username_status == PROPERTY_PRESENT) != (password_status == PROPERTY_PRESENT) ||
      (username_status == PROPERTY_PRESENT &&
       (work->username[0] == '\0' || work->password[0] == '\0')) ||
      (bearer_status == PROPERTY_PRESENT &&
       (work->bearer_token[0] == '\0' || username_status == PROPERTY_PRESENT))) {
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
      {"getRepositoryState", NULL, get_repository_state, NULL, NULL, NULL, napi_default, NULL},
      {"clone", NULL, clone_async, NULL, NULL, NULL, napi_default, NULL},
      {"gitAction", NULL, git_action_async, NULL, NULL, NULL, napi_default, NULL},
  };
  if (napi_define_properties(env, exports,
                             sizeof(properties) / sizeof(properties[0]),
                             properties) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(libgit2_napi, register_module)
