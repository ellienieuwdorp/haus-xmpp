#ifndef OMEMO_BRIDGE_H
#define OMEMO_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
typedef struct om_engine om_engine;
typedef struct om_bytes {
  uint8_t *data;
  size_t length;
} om_bytes;
void om_bytes_free(om_bytes *bytes);
int om_engine_create(om_engine **out, int version, uint32_t device);
void om_engine_free(om_engine *engine);
int om_generate(om_engine *, uint32_t prekey_count);
int om_generate_shared_identity(om_engine *, om_engine *source,
                                uint32_t prekey_count);
int om_replenish(om_engine *, uint32_t first_id, uint32_t count);
size_t om_record_count(om_engine *);
const char *om_record_name(om_engine *, size_t index);
int om_record_read(om_engine *, const char *key, om_bytes *out);
int om_record_write(om_engine *, const char *key, const uint8_t *bytes,
                    size_t length);
int om_public(om_engine *, int kind, uint32_t id,
              om_bytes *out); // 0 identity, 1 signed, 2 signature, 3 prekey
int om_establish(om_engine *, const char *jid, uint32_t device,
                 const uint8_t *identity, size_t identity_len,
                 const uint8_t *signed_key, size_t signed_len,
                 uint32_t signed_id, const uint8_t *sig, size_t sig_len,
                 const uint8_t *prekey, size_t prekey_len, uint32_t prekey_id);
int om_has_session(om_engine *, const char *jid, uint32_t device);
int om_encrypt(om_engine *, const char *jid, uint32_t device,
               const uint8_t *input, size_t length, om_bytes *out,
               int *is_prekey);
int om_decrypt(om_engine *, const char *jid, uint32_t device,
               const uint8_t *input, size_t length, int is_prekey,
               om_bytes *out);
int om_trust(om_engine *, const char *jid, uint32_t device,
             const uint8_t *identity, size_t length, int reset);
int om_equal(const uint8_t *, const uint8_t *, size_t);
int om_rotate_signed_key(om_engine *, uint32_t id, uint64_t timestamp);
void om_delete_signed_key(om_engine *, uint32_t id);
int om_fingerprint(int version, const uint8_t *identity, size_t length,
                   om_bytes *out);
int om_sign(om_engine *, const uint8_t *, size_t, om_bytes *);
int om_verify(int version, const uint8_t *identity, size_t identity_len,
              const uint8_t *message, size_t message_len,
              const uint8_t *signature, size_t signature_len);
int om_aes_cbc(int encrypt, const uint8_t *key, size_t key_len,
               const uint8_t *iv, const uint8_t *input, size_t input_len,
               om_bytes *out);
#endif
