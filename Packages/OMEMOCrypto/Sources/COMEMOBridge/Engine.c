#include "COMEMOBridge.h"
#include <CLibOMEMO.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
struct record {
  char *name;
  signal_buffer *value;
  struct record *next;
};
struct om_engine {
  signal_context *context;
  signal_protocol_store_context *store;
  struct record *records;
  int version;
  uint32_t device;
};
extern int om_install_provider(signal_context *context);
static struct record *find(om_engine *e, const char *key) {
  for (struct record *r = e->records; r; r = r->next)
    if (strcmp(r->name, key) == 0)
      return r;
  return NULL;
}
static int put(om_engine *e, const char *k, const uint8_t *b, size_t n) {
  signal_buffer *v = signal_buffer_create(b, n);
  if (!v)
    return SG_ERR_NOMEM;
  struct record *r = find(e, k);
  if (!r) {
    r = calloc(1, sizeof(*r));
    if (!r) {
      signal_buffer_bzero_free(v);
      return SG_ERR_NOMEM;
    }
    r->name = strdup(k);
    if (!r->name) {
      free(r);
      signal_buffer_bzero_free(v);
      return SG_ERR_NOMEM;
    }
    r->next = e->records;
    e->records = r;
  }
  signal_buffer_bzero_free(r->value);
  r->value = v;
  return 0;
}
static int remove_record(om_engine *e, const char *k) {
  struct record **p = &e->records;
  while (*p) {
    struct record *r = *p;
    if (strcmp(r->name, k) == 0) {
      *p = r->next;
      signal_buffer_bzero_free(r->value);
      free(r->name);
      free(r);
      return 1;
    }
    p = &r->next;
  }
  return 0;
}
static int load(om_engine *e, const char *k, signal_buffer **out) {
  struct record *r = find(e, k);
  if (!r)
    return 0;
  *out = signal_buffer_copy(r->value);
  return *out ? 1 : SG_ERR_NOMEM;
}
static char *address_key(char kind, const signal_protocol_address *a) {
  if (a->name_len > 3071)
    return NULL;
  size_t n = a->name_len + 64;
  char *k = malloc(n);
  if (k)
    snprintf(k, n, "%c:%d:%.*s", kind, a->device_id, (int)a->name_len, a->name);
  return k;
}
static int session_load(signal_buffer **r, signal_buffer **u,
                        const signal_protocol_address *a, void *d) {
  char *k = address_key('s', a);
  if (!k)
    return SG_ERR_NOMEM;
  int result = load(d, k, r);
  free(k);
  return result;
}
static int session_store(const signal_protocol_address *a, uint8_t *r, size_t n,
                         uint8_t *u, size_t un, void *d) {
  char *k = address_key('s', a);
  if (!k)
    return SG_ERR_NOMEM;
  int result = put(d, k, r, n);
  free(k);
  return result;
}
static int session_has(const signal_protocol_address *a, void *d) {
  char *k = address_key('s', a);
  if (!k)
    return 0;
  int result = find(d, k) != NULL;
  free(k);
  return result;
}
static int session_delete(const signal_protocol_address *a, void *d) {
  char *k = address_key('s', a);
  if (!k)
    return SG_ERR_NOMEM;
  int result = remove_record(d, k);
  free(k);
  return result;
}
static int matching_name(const char *k, const char *n, size_t len) {
  if (k[0] != 's' || k[1] != ':')
    return 0;
  const char *sep = strchr(k + 2, ':');
  return sep && strlen(sep + 1) == len && memcmp(sep + 1, n, len) == 0;
}
static int session_devices(signal_int_list **out, const char *n, size_t len,
                           void *d) {
  *out = signal_int_list_alloc();
  if (!*out)
    return SG_ERR_NOMEM;
  int count = 0;
  for (struct record *r = ((om_engine *)d)->records; r; r = r->next)
    if (matching_name(r->name, n, len)) {
      int x = signal_int_list_push_back(*out, atoi(r->name + 2));
      if (x < 0)
        return x;
      count++;
    }
  return count;
}
static int session_delete_all(const char *n, size_t len, void *d) {
  om_engine *e = d;
  int count = 0;
  struct record *r = e->records;
  while (r) {
    struct record *next = r->next;
    if (matching_name(r->name, n, len)) {
      count += remove_record(e, r->name);
    }
    r = next;
  }
  return count;
}
#define KEY_CALLBACKS(prefix, kind)                                            \
  static int prefix##_load(signal_buffer **r, uint32_t id, void *d) {          \
    char k[32];                                                                \
    snprintf(k, sizeof(k), kind ":%u", id);                                    \
    int x = load(d, k, r);                                                     \
    return x == 1 ? 0 : x == 0 ? SG_ERR_INVALID_KEY_ID : x;                    \
  }                                                                            \
  static int prefix##_store(uint32_t id, uint8_t *r, size_t n, void *d) {      \
    char k[32];                                                                \
    snprintf(k, sizeof(k), kind ":%u", id);                                    \
    return put(d, k, r, n);                                                    \
  }                                                                            \
  static int prefix##_has(uint32_t id, void *d) {                              \
    char k[32];                                                                \
    snprintf(k, sizeof(k), kind ":%u", id);                                    \
    return find(d, k) != NULL;                                                 \
  }                                                                            \
  static int prefix##_remove(uint32_t id, void *d) {                           \
    char k[32];                                                                \
    snprintf(k, sizeof(k), kind ":%u", id);                                    \
    remove_record(d, k);                                                       \
    return 0;                                                                  \
  }
KEY_CALLBACKS(pre, "p")
KEY_CALLBACKS(signedpre, "k")
static int identity_pair(signal_buffer **pub, signal_buffer **priv, void *d) {
  int r = load(d, "identity.public", pub);
  if (r != 1)
    return SG_ERR_INVALID_KEY;
  r = load(d, "identity.private", priv);
  if (r != 1) {
    signal_buffer_bzero_free(*pub);
    *pub = NULL;
    return SG_ERR_INVALID_KEY;
  }
  return 0;
}
static int registration(void *d, uint32_t *out) {
  *out = ((om_engine *)d)->device;
  return 0;
}
static int identity_save(const signal_protocol_address *a, uint8_t *b, size_t n,
                         void *d) {
  char *k = address_key('i', a);
  if (!k)
    return SG_ERR_NOMEM;
  int r = b ? put(d, k, b, n) : remove_record(d, k);
  free(k);
  return r < 0 ? r : 0;
}
static int identity_trusted(const signal_protocol_address *a, uint8_t *b,
                            size_t n, void *d) {
  char *k = address_key('i', a);
  if (!k)
    return SG_ERR_NOMEM;
  struct record *r = find(d, k);
  free(k);
  if (!r)
    return 0;
  return signal_buffer_len(r->value) == n &&
         memcmp(signal_buffer_data(r->value), b, n) == 0;
}
int om_engine_create(om_engine **out, int version, uint32_t device) {
  if ((version != 3 && version != 4) || !device || device > INT32_MAX)
    return SG_ERR_INVAL;
  om_engine *e = calloc(1, sizeof(*e));
  if (!e)
    return SG_ERR_NOMEM;
  e->version = version;
  e->device = device;
  int r = signal_context_create(&e->context, e);
  if (r < 0)
    goto fail;
  r = om_install_provider(e->context);
  if (r < 0)
    goto fail;
  r = signal_protocol_store_context_create(&e->store, e->context);
  if (r < 0)
    goto fail;
  signal_protocol_session_store ss = {
      session_load,   session_devices,    session_store, session_has,
      session_delete, session_delete_all, NULL,          e};
  signal_protocol_pre_key_store ps = {pre_load,   pre_store, pre_has,
                                      pre_remove, NULL,      e};
  signal_protocol_signed_pre_key_store ks = {signedpre_load, signedpre_store,
                                             signedpre_has,  signedpre_remove,
                                             NULL,           e};
  signal_protocol_identity_key_store is = {
      identity_pair, registration, identity_save, identity_trusted, NULL, e};
  if ((r = signal_protocol_store_context_set_session_store(e->store, &ss)) < 0)
    goto fail;
  if ((r = signal_protocol_store_context_set_pre_key_store(e->store, &ps)) < 0)
    goto fail;
  if ((r = signal_protocol_store_context_set_signed_pre_key_store(e->store,
                                                                  &ks)) < 0)
    goto fail;
  if ((r = signal_protocol_store_context_set_identity_key_store(e->store,
                                                                &is)) < 0)
    goto fail;
  *out = e;
  return 0;
fail:
  om_engine_free(e);
  return r;
}
void om_engine_free(om_engine *e) {
  if (!e)
    return;
  if (e->store)
    signal_protocol_store_context_destroy(e->store);
  if (e->context)
    signal_context_destroy(e->context);
  while (e->records)
    remove_record(e, e->records->name);
  free(e);
}
void om_bytes_free(om_bytes *b) {
  if (!b)
    return;
  if (b->data) {
    memset_s(b->data, b->length, 0, b->length);
    free(b->data);
  }
  b->data = NULL;
  b->length = 0;
}
static int copy_out(signal_buffer *b, om_bytes *out) {
  if (!b)
    return SG_ERR_NOMEM;
  out->length = signal_buffer_len(b);
  out->data = malloc(out->length ? out->length : 1);
  if (!out->data)
    return SG_ERR_NOMEM;
  memcpy(out->data, signal_buffer_data(b), out->length);
  return 0;
}
size_t om_record_count(om_engine *e) {
  size_t n = 0;
  for (struct record *r = e->records; r; r = r->next)
    n++;
  return n;
}
const char *om_record_name(om_engine *e, size_t index) {
  struct record *r = e->records;
  while (r && index--) {
    r = r->next;
  }
  return r ? r->name : NULL;
}
int om_record_read(om_engine *e, const char *k, om_bytes *out) {
  struct record *r = find(e, k);
  return r ? copy_out(r->value, out) : SG_ERR_INVALID_KEY_ID;
}
int om_record_write(om_engine *e, const char *k, const uint8_t *b, size_t n) {
  return put(e, k, b, n);
}
int om_replenish(om_engine *e, uint32_t first, uint32_t count) {
  if (count > 1000 || !first || first > 0xFFFFFF - count)
    return SG_ERR_INVAL;
  signal_protocol_key_helper_pre_key_list_node *head = NULL;
  int r = signal_protocol_key_helper_generate_pre_keys(&head, first, count,
                                                       e->context);
  if (r < 0)
    return r;
  for (signal_protocol_key_helper_pre_key_list_node *n = head; n;
       n = signal_protocol_key_helper_key_list_next(n)) {
    session_pre_key *k = signal_protocol_key_helper_key_list_element(n);
    r = signal_protocol_pre_key_store_key(e->store, k);
    if (r < 0)
      break;
  }
  signal_protocol_key_helper_key_list_free(head);
  return r;
}
int om_generate(om_engine *e, uint32_t count) {
  ratchet_identity_key_pair *i = NULL;
  session_signed_pre_key *k = NULL;
  signal_buffer *b = NULL;
  int r = signal_protocol_key_helper_generate_identity_key_pair(&i, e->context);
  if (r < 0)
    goto done;
  r = ec_public_key_serialize(&b, ratchet_identity_key_pair_get_public(i));
  if (r < 0)
    goto done;
  r = put(e, "identity.public", signal_buffer_data(b), signal_buffer_len(b));
  signal_buffer_bzero_free(b);
  b = NULL;
  if (r < 0)
    goto done;
  r = ec_private_key_serialize(&b, ratchet_identity_key_pair_get_private(i));
  if (r < 0)
    goto done;
  r = put(e, "identity.private", signal_buffer_data(b), signal_buffer_len(b));
  if (r < 0)
    goto done;
  r = signal_protocol_key_helper_generate_signed_pre_key(
      &k, i, 1, (uint64_t)time(NULL) * 1000, e->context);
  if (r < 0)
    goto done;
  r = signal_protocol_signed_pre_key_store_key(e->store, k);
  if (r < 0)
    goto done;
  r = om_replenish(e, 1, count);
done:
  signal_buffer_bzero_free(b);
  SIGNAL_UNREF(k);
  SIGNAL_UNREF(i);
  return r;
}
int om_public(om_engine *e, int kind, uint32_t id, om_bytes *out) {
  ratchet_identity_key_pair *i = NULL;
  session_pre_key *p = NULL;
  session_signed_pre_key *s = NULL;
  ec_public_key *key = NULL;
  signal_buffer *b = NULL;
  int r = 0;
  if (kind == 0) {
    r = signal_protocol_identity_get_key_pair(e->store, &i);
    if (r < 0)
      goto done;
    key = ratchet_identity_key_pair_get_public(i);
    if (e->version == 4) {
      b = ec_public_key_get_ed(key);
      r = b ? 0 : SG_ERR_NOMEM;
      goto serialize_done;
    }
  } else if (kind == 3) {
    r = signal_protocol_pre_key_load_key(e->store, &p, id);
    if (r < 0)
      goto done;
    key = ec_key_pair_get_public(session_pre_key_get_key_pair(p));
  } else {
    r = signal_protocol_signed_pre_key_load_key(e->store, &s, id);
    if (r < 0)
      goto done;
    if (kind == 2) {
      const uint8_t *sig = e->version == 4
                               ? session_signed_pre_key_get_signature_omemo(s)
                               : session_signed_pre_key_get_signature(s);
      size_t len = e->version == 4
                       ? session_signed_pre_key_get_signature_omemo_len(s)
                       : session_signed_pre_key_get_signature_len(s);
      b = signal_buffer_create(sig, len);
      r = b ? 0 : SG_ERR_NOMEM;
      goto serialize_done;
    }
    key = ec_key_pair_get_public(session_signed_pre_key_get_key_pair(s));
  }
  r = e->version == 4 ? ec_public_key_serialize_omemo(&b, key)
                      : ec_public_key_serialize(&b, key);
serialize_done:
  if (r >= 0)
    r = copy_out(b, out);
done:
  signal_buffer_bzero_free(b);
  SIGNAL_UNREF(i);
  SIGNAL_UNREF(p);
  SIGNAL_UNREF(s);
  return r;
}
int om_establish(om_engine *e, const char *jid, uint32_t device,
                 const uint8_t *ik, size_t il, const uint8_t *sk, size_t sl,
                 uint32_t sid, const uint8_t *sig, size_t sigl,
                 const uint8_t *pk, size_t pl, uint32_t pid) {
  ec_public_key *i = NULL, *s = NULL, *p = NULL;
  session_pre_key_bundle *b = NULL;
  session_builder *builder = NULL;
  signal_protocol_address a = {jid, strlen(jid), (int32_t)device};
  int r = e->version == 4 ? curve_decode_point_ed(&i, ik, il, e->context)
                          : curve_decode_point(&i, ik, il, e->context);
  if (r < 0)
    goto done;
  r = e->version == 4 ? curve_decode_point_mont(&s, sk, sl, e->context)
                      : curve_decode_point(&s, sk, sl, e->context);
  if (r < 0)
    goto done;
  r = e->version == 4 ? curve_decode_point_mont(&p, pk, pl, e->context)
                      : curve_decode_point(&p, pk, pl, e->context);
  if (r < 0)
    goto done;
  r = session_pre_key_bundle_create(&b, device, (int)device, pid, p, sid, s,
                                    sig, sigl, i);
  if (r < 0)
    goto done;
  r = session_builder_create(&builder, e->store, &a, e->context);
  if (r < 0)
    goto done;
  session_builder_set_version(builder, e->version);
  r = session_builder_process_pre_key_bundle(builder, b);
done:
  if (builder)
    session_builder_free(builder);
  SIGNAL_UNREF(b);
  SIGNAL_UNREF(i);
  SIGNAL_UNREF(s);
  SIGNAL_UNREF(p);
  return r;
}
int om_has_session(om_engine *e, const char *jid, uint32_t device) {
  signal_protocol_address a = {jid, strlen(jid), (int32_t)device};
  return session_has(&a, e);
}
int om_encrypt(om_engine *e, const char *jid, uint32_t device,
               const uint8_t *input, size_t length, om_bytes *out,
               int *is_prekey) {
  signal_protocol_address a = {jid, strlen(jid), (int32_t)device};
  session_cipher *c = NULL;
  ciphertext_message *m = NULL;
  int r = session_cipher_create(&c, e->store, &a, e->context);
  if (r < 0)
    goto done;
  session_cipher_set_version(c, e->version);
  r = session_cipher_encrypt(c, input, length, &m);
  if (r < 0)
    goto done;
  *is_prekey = ciphertext_message_get_type(m) == CIPHERTEXT_PREKEY_TYPE;
  r = copy_out(ciphertext_message_get_serialized(m), out);
done:
  SIGNAL_UNREF(m);
  if (c)
    session_cipher_free(c);
  return r;
}
int om_decrypt(om_engine *e, const char *jid, uint32_t device,
               const uint8_t *input, size_t length, int is_prekey,
               om_bytes *out) {
  signal_protocol_address a = {jid, strlen(jid), (int32_t)device};
  session_cipher *c = NULL;
  signal_message *m = NULL;
  pre_key_signal_message *p = NULL;
  signal_buffer *b = NULL;
  int r = session_cipher_create(&c, e->store, &a, e->context);
  if (r < 0)
    goto done;
  session_cipher_set_version(c, e->version);
  if (is_prekey) {
    r = e->version == 4
            ? pre_key_signal_message_deserialize_omemo(&p, input, length,
                                                       device, e->context)
            : pre_key_signal_message_deserialize(&p, input, length, e->context);
    if (r < 0)
      goto done;
    if (e->version == 4 && (!pre_key_signal_message_has_pre_key_id(p) ||
                            pre_key_signal_message_get_pre_key_id(p) == 0)) {
      r = SG_ERR_INVALID_MESSAGE;
      goto done;
    }
    r = session_cipher_decrypt_pre_key_signal_message(c, p, NULL, &b);
  } else {
    r = e->version == 4
            ? signal_message_deserialize_omemo(&m, input, length, e->context)
            : signal_message_deserialize(&m, input, length, e->context);
    if (r < 0)
      goto done;
    r = session_cipher_decrypt_signal_message(c, m, NULL, &b);
  }
  if (r >= 0)
    r = copy_out(b, out);
done:
  signal_buffer_bzero_free(b);
  SIGNAL_UNREF(m);
  SIGNAL_UNREF(p);
  if (c)
    session_cipher_free(c);
  return r;
}
int om_sign(om_engine *e, const uint8_t *input, size_t length, om_bytes *out) {
  ratchet_identity_key_pair *i = NULL;
  signal_buffer *b = NULL;
  int r = signal_protocol_identity_get_key_pair(e->store, &i);
  if (r < 0)
    goto done;
  r = curve_calculate_signature(
      e->context, &b, ratchet_identity_key_pair_get_private(i), input, length);
  if (r >= 0)
    r = copy_out(b, out);
done:
  signal_buffer_bzero_free(b);
  SIGNAL_UNREF(i);
  return r;
}

int om_trust(om_engine *e, const char *jid, uint32_t device,
             const uint8_t *input, size_t length, int reset) {
  ec_public_key *k = NULL;
  signal_buffer *b = NULL;
  signal_protocol_address a = {jid, strlen(jid), (int32_t)device};
  int r = e->version == 4 ? curve_decode_point_ed(&k, input, length, e->context)
                          : curve_decode_point(&k, input, length, e->context);
  if (r < 0)
    goto done;
  r = ec_public_key_serialize(&b, k);
  if (r < 0)
    goto done;
  char *name = address_key('i', &a);
  if (!name) {
    r = SG_ERR_NOMEM;
    goto done;
  }
  struct record *old = find(e, name);
  free(name);
  if (old &&
      !identity_trusted(&a, signal_buffer_data(b), signal_buffer_len(b), e)) {
    if (!reset) {
      r = SG_ERR_UNTRUSTED_IDENTITY;
      goto done;
    }
    session_delete(&a, e);
  }
  r = identity_save(&a, signal_buffer_data(b), signal_buffer_len(b), e);
done:
  signal_buffer_bzero_free(b);
  SIGNAL_UNREF(k);
  return r;
}

int om_equal(const uint8_t *a, const uint8_t *b, size_t length) {
  signal_buffer *x = signal_buffer_create(a, length),
                *y = signal_buffer_create(b, length);
  int result = x && y && signal_buffer_compare(x, y) == 0;
  signal_buffer_bzero_free(x);
  signal_buffer_bzero_free(y);
  return result;
}

int om_rotate_signed_key(om_engine *e, uint32_t id, uint64_t timestamp) {
  ratchet_identity_key_pair *i = NULL;
  session_signed_pre_key *k = NULL;
  int r = signal_protocol_identity_get_key_pair(e->store, &i);
  if (r < 0)
    goto done;
  r = signal_protocol_key_helper_generate_signed_pre_key(&k, i, id, timestamp,
                                                         e->context);
  if (r < 0)
    goto done;
  r = signal_protocol_signed_pre_key_store_key(e->store, k);
done:
  SIGNAL_UNREF(i);
  SIGNAL_UNREF(k);
  return r;
}
void om_delete_signed_key(om_engine *e, uint32_t id) {
  signedpre_remove(id, e);
}

int om_fingerprint(int version, const uint8_t *identity, size_t length,
                   om_bytes *out) {
  signal_context *context = NULL;
  ec_public_key *key = NULL;
  signal_buffer *buffer = NULL;
  int r = signal_context_create(&context, NULL);
  if (r < 0)
    goto done;
  r = version == 4 ? curve_decode_point_ed(&key, identity, length, context)
                   : curve_decode_point(&key, identity, length, context);
  if (r < 0)
    goto done;
  buffer = ec_public_key_get_mont(key);
  if (!buffer) {
    r = SG_ERR_NOMEM;
    goto done;
  }
  r = copy_out(buffer, out);
done:
  signal_buffer_bzero_free(buffer);
  SIGNAL_UNREF(key);
  if (context)
    signal_context_destroy(context);
  return r;
}

int om_generate_shared_identity(om_engine *engine, om_engine *source,
                                uint32_t count) {
  if (engine->device != source->device)
    return SG_ERR_INVAL;
  struct record *pub = find(source, "identity.public");
  struct record *priv = find(source, "identity.private");
  if (!pub || !priv)
    return SG_ERR_INVALID_KEY;
  int result = put(engine, "identity.public", signal_buffer_data(pub->value),
                   signal_buffer_len(pub->value));
  if (result < 0)
    return result;
  result = put(engine, "identity.private", signal_buffer_data(priv->value),
               signal_buffer_len(priv->value));
  if (result < 0)
    return result;
  result = om_rotate_signed_key(engine, 1, (uint64_t)time(NULL) * 1000);
  if (result < 0)
    return result;
  return om_replenish(engine, 1, count);
}

// Signature verification delegates to the pinned upstream implementation. It does not
// touch a session or a trust record, so discovery can reject malformed signed bundles.
int om_verify(int version, const uint8_t *identity, size_t identity_len,
              const uint8_t *message, size_t message_len,
              const uint8_t *signature, size_t signature_len) {
  signal_context *context = NULL;
  ec_public_key *key = NULL;
  int r = signal_context_create(&context, NULL);
  if (r < 0)
    goto done;
  r = version == 4 ? curve_decode_point_ed(&key, identity, identity_len, context)
                   : curve_decode_point(&key, identity, identity_len, context);
  if (r >= 0)
    r = curve_verify_signature(key, message, message_len, signature, signature_len);
done:
  SIGNAL_UNREF(key);
  if (context)
    signal_context_destroy(context);
  return r;
}
