#include "COMEMOBridge.h"
#include <CLibOMEMO.h>
#include <CommonCrypto/CommonCrypto.h>
#include <Security/SecRandom.h>
#include <stdlib.h>
#include <string.h>
static int random_bytes(uint8_t *bytes, size_t length, void *unused) {
  return SecRandomCopyBytes(kSecRandomDefault, length, bytes) == errSecSuccess
             ? 0
             : SG_ERR_UNKNOWN;
}
static int hmac_init(void **context, const uint8_t *key, size_t length,
                     void *unused) {
  CCHmacContext *c = malloc(sizeof(*c));
  if (!c)
    return SG_ERR_NOMEM;
  CCHmacInit(c, kCCHmacAlgSHA256, key, length);
  *context = c;
  return 0;
}
static int hmac_update(void *c, const uint8_t *data, size_t length,
                       void *unused) {
  CCHmacUpdate(c, data, length);
  return 0;
}
static int hmac_final(void *c, signal_buffer **output, void *unused) {
  *output = signal_buffer_alloc(CC_SHA256_DIGEST_LENGTH);
  if (!*output)
    return SG_ERR_NOMEM;
  CCHmacFinal(c, signal_buffer_data(*output));
  return 0;
}
static void hmac_free(void *c, void *unused) {
  if (c) {
    memset_s(c, sizeof(CCHmacContext), 0, sizeof(CCHmacContext));
    free(c);
  }
}
static int sha_init(void **context, void *unused) {
  CC_SHA512_CTX *c = malloc(sizeof(*c));
  if (!c)
    return SG_ERR_NOMEM;
  CC_SHA512_Init(c);
  *context = c;
  return 0;
}
static int sha_update(void *c, const uint8_t *data, size_t length,
                      void *unused) {
  if (length > UINT32_MAX)
    return SG_ERR_INVAL;
  return CC_SHA512_Update(c, data, (CC_LONG)length) ? 0 : SG_ERR_UNKNOWN;
}
static int sha_final(void *c, signal_buffer **out, void *unused) {
  *out = signal_buffer_alloc(CC_SHA512_DIGEST_LENGTH);
  if (!*out)
    return SG_ERR_NOMEM;
  CC_SHA512_Final(signal_buffer_data(*out), c);
  CC_SHA512_Init(c);
  return 0;
}
static void sha_free(void *c, void *unused) {
  if (c) {
    memset_s(c, sizeof(CC_SHA512_CTX), 0, sizeof(CC_SHA512_CTX));
    free(c);
  }
}
static int aes(signal_buffer **out, int encrypt, int cipher, const uint8_t *key,
               size_t key_len, const uint8_t *iv, size_t iv_len,
               const uint8_t *input, size_t length) {
  if (iv_len != 16 || (key_len != 16 && key_len != 32) ||
      length > 16 * 1024 * 1024 + 16)
    return SG_ERR_INVAL;
  CCCryptorRef c = NULL;
  CCCryptorStatus status;
  if (cipher == SG_CIPHER_AES_CBC_PKCS5)
    status = CCCryptorCreate(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES,
                             kCCOptionPKCS7Padding, key, key_len, iv, &c);
  else if (cipher == SG_CIPHER_AES_CTR_NOPADDING)
    status = CCCryptorCreateWithMode(
        encrypt ? kCCEncrypt : kCCDecrypt, kCCModeCTR, kCCAlgorithmAES,
        ccNoPadding, iv, key, key_len, NULL, 0, 0, kCCModeOptionCTR_BE, &c);
  else
    return SG_ERR_INVAL;
  if (status != kCCSuccess)
    return SG_ERR_UNKNOWN;
  size_t cap = CCCryptorGetOutputLength(c, length, true);
  uint8_t *buffer = malloc(cap ? cap : 1);
  if (!buffer) {
    CCCryptorRelease(c);
    return SG_ERR_NOMEM;
  }
  size_t n = 0, m = 0;
  status = CCCryptorUpdate(c, input, length, buffer, cap, &n);
  if (status == kCCSuccess)
    status = CCCryptorFinal(c, buffer + n, cap - n, &m);
  int result = SG_ERR_UNKNOWN;
  if (status == kCCSuccess) {
    *out = signal_buffer_create(buffer, n + m);
    result = *out ? 0 : SG_ERR_NOMEM;
  }
  memset_s(buffer, cap, 0, cap);
  free(buffer);
  CCCryptorRelease(c);
  return result;
}
static int encrypt_cb(signal_buffer **o, int c, const uint8_t *k, size_t kl,
                      const uint8_t *i, size_t il, const uint8_t *p, size_t pl,
                      void *u) {
  return aes(o, 1, c, k, kl, i, il, p, pl);
}
static int decrypt_cb(signal_buffer **o, int c, const uint8_t *k, size_t kl,
                      const uint8_t *i, size_t il, const uint8_t *p, size_t pl,
                      void *u) {
  return aes(o, 0, c, k, kl, i, il, p, pl);
}
int om_install_provider(signal_context *context) {
  signal_crypto_provider p = {random_bytes, hmac_init,  hmac_update, hmac_final,
                              hmac_free,    sha_init,   sha_update,  sha_final,
                              sha_free,     encrypt_cb, decrypt_cb,  NULL};
  return signal_context_set_crypto_provider(context, &p);
}
int om_aes_cbc(int encrypt, const uint8_t *key, size_t key_len,
               const uint8_t *iv, const uint8_t *input, size_t input_len,
               om_bytes *out) {
  signal_buffer *b = NULL;
  int r = aes(&b, encrypt, SG_CIPHER_AES_CBC_PKCS5, key, key_len, iv, 16, input,
              input_len);
  if (r < 0)
    return r;
  out->length = signal_buffer_len(b);
  out->data = malloc(out->length ? out->length : 1);
  if (!out->data) {
    signal_buffer_bzero_free(b);
    return SG_ERR_NOMEM;
  }
  memcpy(out->data, signal_buffer_data(b), out->length);
  signal_buffer_bzero_free(b);
  return 0;
}
