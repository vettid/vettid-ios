/*
 * The single compilation unit of the vendored mlkem-native (monolithic build,
 * mlkem-native/mlkem_native.c), configured by vettid_mlkem_config.h, and the
 * functions of include/vettid_mlkem.h over it.
 */
#define MLK_CONFIG_FILE "vettid_mlkem_config.h"

#include "mlkem_native.c"
#include "mlkem_native.h"
#include "vettid_mlkem.h"

int vettid_mlkem768_keypair_derand(uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES],
                                   uint8_t sk[VETTID_MLKEM768_SECRETKEYBYTES],
                                   const uint8_t coins[64])
{
  return vettid_mlkem_keypair_derand(pk, sk, coins);
}

int vettid_mlkem768_enc_derand(uint8_t ct[VETTID_MLKEM768_CIPHERTEXTBYTES],
                               uint8_t ss[VETTID_MLKEM768_SSBYTES],
                               const uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES],
                               const uint8_t coins[32])
{
  return vettid_mlkem_enc_derand(ct, ss, pk, coins);
}

int vettid_mlkem768_dec(uint8_t ss[VETTID_MLKEM768_SSBYTES],
                        const uint8_t ct[VETTID_MLKEM768_CIPHERTEXTBYTES],
                        const uint8_t sk[VETTID_MLKEM768_SECRETKEYBYTES])
{
  return vettid_mlkem_dec(ss, ct, sk);
}

int vettid_mlkem768_check_pk(const uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES])
{
  return vettid_mlkem_check_pk(pk);
}

/* mlkem-native's FIPS 202 functions are static in this compilation unit
 * (MLK_CONFIG_INTERNAL_API_QUALIFIER); their namespaced names stay defined. */
void vettid_shake256(uint8_t *output, size_t outlen, const uint8_t *input, size_t inlen)
{
  vettid_mlkem_shake256(output, outlen, input, inlen);
}

void vettid_sha3_256(uint8_t output[32], const uint8_t *input, size_t inlen)
{
  vettid_mlkem_sha3_256(output, input, inlen);
}
