/*
 * ML-KEM-768 (FIPS 203) and the SHA-3 functions X-Wing needs, from the
 * vendored mlkem-native (mlkem-native/, see SOURCE.md). Every function takes
 * its randomness from the caller.
 */
#ifndef VETTID_MLKEM_H
#define VETTID_MLKEM_H

#include <stddef.h>
#include <stdint.h>

#define VETTID_MLKEM768_PUBLICKEYBYTES 1184
#define VETTID_MLKEM768_SECRETKEYBYTES 2400
#define VETTID_MLKEM768_CIPHERTEXTBYTES 1088
#define VETTID_MLKEM768_SSBYTES 32

/* ML-KEM.KeyGen_internal(d = coins[0:32], z = coins[32:64]). 0 on success. */
int vettid_mlkem768_keypair_derand(uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES],
                                   uint8_t sk[VETTID_MLKEM768_SECRETKEYBYTES],
                                   const uint8_t coins[64]);

/* ML-KEM.Encaps_internal(pk, m = coins). 0 on success; non-zero when pk fails the modulus check. */
int vettid_mlkem768_enc_derand(uint8_t ct[VETTID_MLKEM768_CIPHERTEXTBYTES],
                               uint8_t ss[VETTID_MLKEM768_SSBYTES],
                               const uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES],
                               const uint8_t coins[32]);

/* ML-KEM.Decaps(sk, ct). 0 on success; non-zero when sk fails the hash check. */
int vettid_mlkem768_dec(uint8_t ss[VETTID_MLKEM768_SSBYTES],
                        const uint8_t ct[VETTID_MLKEM768_CIPHERTEXTBYTES],
                        const uint8_t sk[VETTID_MLKEM768_SECRETKEYBYTES]);

/* The FIPS 203 §7.2 modulus check of an encapsulation key. 0 when it passes. */
int vettid_mlkem768_check_pk(const uint8_t pk[VETTID_MLKEM768_PUBLICKEYBYTES]);

/* SHAKE256(input) → outlen bytes (FIPS 202). */
void vettid_shake256(uint8_t *output, size_t outlen, const uint8_t *input, size_t inlen);

/* SHA3-256(input) (FIPS 202). */
void vettid_sha3_256(uint8_t output[32], const uint8_t *input, size_t inlen);

#endif
