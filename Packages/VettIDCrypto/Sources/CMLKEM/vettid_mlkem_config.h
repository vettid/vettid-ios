/*
 * mlkem-native configuration for VettID (IOS-PLAN ID6): ML-KEM-768 only, the
 * portable C code (no native backends), the derandomized API only (every
 * caller supplies its randomness, from VettIDCrypto's Randomness), and every
 * internal function static to the single compilation unit vettid_mlkem.c.
 * The other options keep the upstream defaults of mlkem_native_config.h.
 */
#ifndef VETTID_MLKEM_CONFIG_H
#define VETTID_MLKEM_CONFIG_H

#define MLK_CONFIG_PARAMETER_SET 768
#define MLK_CONFIG_NAMESPACE_PREFIX vettid_mlkem
#define MLK_CONFIG_NO_RANDOMIZED_API
#define MLK_CONFIG_INTERNAL_API_QUALIFIER static

#include "mlkem_native_config.h"

#endif
