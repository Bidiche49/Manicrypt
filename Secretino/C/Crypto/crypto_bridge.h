//
//  crypto_bridge.h
//  Secretino
//
//  Bridge header pour exposer les fonctions C à Swift
//
// crypto_bridge.h - CORRECTED
#ifndef crypto_bridge_h
#define crypto_bridge_h

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// OpenSSL headers only
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/bio.h>
#include <openssl/buffer.h>

#include "../Utils/utils.h"

// Constantes de crypto.h
#define SALT_SIZE 32
#define IV_SIZE 12
#define KEY_SIZE 32
#define TAG_SIZE 16
#define ITERATIONS 100000

// Structure pour retourner les résultats à Swift
typedef struct {
    unsigned char *data;
    int length;
    int success;
    char *error_message;
} CryptoResult;

// Fonctions exposées à Swift (crypto uniquement)
CryptoResult* swift_encrypt_data(const char *plaintext, const char *passphrase);
CryptoResult* swift_decrypt_data(const unsigned char *ciphertext, int ciphertext_len, const char *passphrase);
char* swift_base64_encode(const unsigned char *input, int length);
CryptoResult* swift_base64_decode(const char *input);

// Fonction pour libérer la mémoire depuis Swift
void free_crypto_result(CryptoResult *result);

// Fonction d'initialisation OpenSSL
void init_openssl(void);
void cleanup_openssl(void);

#endif /* crypto_bridge_h */
