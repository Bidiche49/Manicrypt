//
//  crypto_bridge.c
//  SecureCrypto
//
//  Implémentation du bridge entre Swift et les fonctions crypto C
//

#include "crypto_bridge.h"

// Effacement mémoire de niveau militaire pour macOS
static void military_grade_zero(void *ptr, size_t len) {
    if (ptr == NULL || len == 0) return;
    
    volatile unsigned char *vptr = (volatile unsigned char*)ptr;
    
    // Triple passage avec patterns différents (standard militaire DoD 5220.22-M)
    for (size_t i = 0; i < len; i++) {
        vptr[i] = 0x00;
    }
    
    for (size_t i = 0; i < len; i++) {
        vptr[i] = 0xFF;
    }
    
    for (size_t i = 0; i < len; i++) {
        vptr[i] = 0x00;
    }
    
    // Barrière mémoire forte pour empêcher toute optimisation
    __asm__ __volatile__("" ::: "memory");
    __sync_synchronize(); // Barrière supplémentaire
}

// Macro de remplacement pour explicit_bzero
#define explicit_bzero(ptr, len) military_grade_zero(ptr, len)

// Fonction pour dériver une clé à partir d'une passphrase
static int derive_key(const char *passphrase, const unsigned char *salt, unsigned char *key) {
    if (PKCS5_PBKDF2_HMAC(passphrase, (int)ft_strlen(passphrase), salt, SALT_SIZE,
                        ITERATIONS, EVP_sha256(), KEY_SIZE, key) != 1) {
        return 0;
    }
    return 1;
}

// Wrapper pour chiffrer - compatible Swift
CryptoResult* swift_encrypt_data(const char *plaintext, const char *passphrase) {
    CryptoResult *result = malloc(sizeof(CryptoResult));
    if (!result) return NULL;
    
    // Initialiser la structure
    result->data = NULL;
    result->length = 0;
    result->success = 0;
    result->error_message = malloc(256);  // Allouer la mémoire pour le message d'erreur
    if (!result->error_message) {
        free(result);
        return NULL;
    }
    result->error_message[0] = '\0';  // Initialiser comme string vide
    
    EVP_CIPHER_CTX *ctx;
    int len;
    int plaintext_len = (int)ft_strlen(plaintext);
    unsigned char salt[SALT_SIZE];
    unsigned char key[KEY_SIZE];
    unsigned char iv[IV_SIZE];
    unsigned char tag[TAG_SIZE];

    // Générer sel et IV aléatoires
    if (RAND_bytes(salt, SALT_SIZE) != 1 || RAND_bytes(iv, IV_SIZE) != 1) {
        strcpy(result->error_message, "Erreur lors de la génération de nombres aléatoires");
        return result;
    }

    // Dériver la clé
    if (!derive_key(passphrase, salt, key)) {
        strcpy(result->error_message, "Erreur lors de la dérivation de la clé");
        return result;
    }

    // Allouer mémoire pour le texte chiffré
    result->data = malloc(SALT_SIZE + IV_SIZE + plaintext_len + TAG_SIZE);
    if (result->data == NULL) {
        strcpy(result->error_message, "Erreur d'allocation mémoire");
        return result;
    }

    // Copier sel et IV au début
    memcpy(result->data, salt, SALT_SIZE);
    memcpy(result->data + SALT_SIZE, iv, IV_SIZE);

    // Créer et initialiser le contexte
    ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        strcpy(result->error_message, "Erreur de contexte OpenSSL");
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Initialiser le chiffrement
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, key, iv) != 1) {
        strcpy(result->error_message, "Erreur d'initialisation du chiffrement");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Chiffrer
    if (EVP_EncryptUpdate(ctx, result->data + SALT_SIZE + IV_SIZE, &len,
                        (unsigned char *)plaintext, plaintext_len) != 1) {
        strcpy(result->error_message, "Erreur lors du chiffrement");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }
    result->length = len;

    // Finaliser
    if (EVP_EncryptFinal_ex(ctx, result->data + SALT_SIZE + IV_SIZE + len, &len) != 1) {
        strcpy(result->error_message, "Erreur de finalisation du chiffrement");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }
    result->length += len;

    // Obtenir le tag d'authentification
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_SIZE, tag) != 1) {
        strcpy(result->error_message, "Erreur d'obtention du tag");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Ajouter le tag à la fin
    memcpy(result->data + SALT_SIZE + IV_SIZE + result->length, tag, TAG_SIZE);
    result->length = SALT_SIZE + IV_SIZE + result->length + TAG_SIZE;

    EVP_CIPHER_CTX_free(ctx);

    // Nettoyer la clé de la mémoire (niveau militaire)
    military_grade_zero(key, KEY_SIZE);
    
    result->success = 1;
    return result;
}

// Wrapper pour déchiffrer - compatible Swift
CryptoResult* swift_decrypt_data(const unsigned char *ciphertext, int ciphertext_len, const char *passphrase) {
    CryptoResult *result = malloc(sizeof(CryptoResult));
    if (!result) return NULL;
    
    // Initialiser la structure
    result->data = NULL;
    result->length = 0;
    result->success = 0;
    result->error_message = malloc(256);  // Allouer la mémoire pour le message d'erreur
    if (!result->error_message) {
        free(result);
        return NULL;
    }
    result->error_message[0] = '\0';  // Initialiser comme string vide

    EVP_CIPHER_CTX *ctx;
    int len;
    unsigned char salt[SALT_SIZE];
    unsigned char key[KEY_SIZE];
    unsigned char iv[IV_SIZE];
    unsigned char tag[TAG_SIZE];
    int actual_ciphertext_len = ciphertext_len - SALT_SIZE - IV_SIZE - TAG_SIZE;

    if (ciphertext_len < SALT_SIZE + IV_SIZE + TAG_SIZE) {
        strcpy(result->error_message, "Données chiffrées invalides");
        return result;
    }

    // Extraire sel, IV et tag
    memcpy(salt, ciphertext, SALT_SIZE);
    memcpy(iv, ciphertext + SALT_SIZE, IV_SIZE);
    memcpy(tag, ciphertext + ciphertext_len - TAG_SIZE, TAG_SIZE);

    // Dériver la clé
    if (!derive_key(passphrase, salt, key)) {
        strcpy(result->error_message, "Erreur lors de la dérivation de la clé");
        return result;
    }

    // Allouer mémoire pour le texte déchiffré
    result->data = malloc(actual_ciphertext_len + 1);
    if (result->data == NULL) {
        strcpy(result->error_message, "Erreur d'allocation mémoire");
        return result;
    }

    // Créer et initialiser le contexte
    ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        strcpy(result->error_message, "Erreur de contexte OpenSSL");
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Initialiser le déchiffrement
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, key, iv) != 1) {
        strcpy(result->error_message, "Erreur d'initialisation du déchiffrement");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Déchiffrer
    if (EVP_DecryptUpdate(ctx, result->data, &len,
                        ciphertext + SALT_SIZE + IV_SIZE, actual_ciphertext_len) != 1) {
        strcpy(result->error_message, "Erreur lors du déchiffrement");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }
    result->length = len;

    // Définir le tag pour vérification
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_SIZE, tag) != 1) {
        strcpy(result->error_message, "Erreur de définition du tag");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }

    // Finaliser et vérifier l'authenticité
    if (EVP_DecryptFinal_ex(ctx, result->data + len, &len) != 1) {
        strcpy(result->error_message, "Authentification échouée ou passphrase incorrecte");
        EVP_CIPHER_CTX_free(ctx);
        free(result->data);
        result->data = NULL;
        return result;
    }
    result->length += len;

    // Terminer par null
    result->data[result->length] = '\0';

    EVP_CIPHER_CTX_free(ctx);

    // Nettoyer la clé
    explicit_bzero(key, KEY_SIZE);
    
    result->success = 1;
    return result;
}

// Wrapper pour base64 encode
char* swift_base64_encode(const unsigned char *input, int length) {
    BIO *bio, *b64;
    BUF_MEM *buffer_ptr;
    char *b64text;

    b64 = BIO_new(BIO_f_base64());
    bio = BIO_new(BIO_s_mem());
    bio = BIO_push(b64, bio);

    BIO_set_flags(bio, BIO_FLAGS_BASE64_NO_NL);
    BIO_write(bio, input, length);
    BIO_flush(bio);

    BIO_get_mem_ptr(bio, &buffer_ptr);

    b64text = malloc(buffer_ptr->length + 1);
    memcpy(b64text, buffer_ptr->data, buffer_ptr->length);
    b64text[buffer_ptr->length] = '\0';

    BIO_free_all(bio);

    return b64text;
}

// Wrapper pour base64 decode
CryptoResult* swift_base64_decode(const char *input) {
    CryptoResult *result = malloc(sizeof(CryptoResult));
    if (!result) return NULL;
    
    result->data = NULL;
    result->length = 0;
    result->success = 0;
    result->error_message = malloc(256);  // Allouer la mémoire pour le message d'erreur
    if (!result->error_message) {
        free(result);
        return NULL;
    }
    result->error_message[0] = '\0';  // Initialiser comme string vide

    BIO *bio, *b64;
    int decode_len = (int)ft_strlen(input);
    result->data = malloc(decode_len);
    
    if (!result->data) {
        strcpy(result->error_message, "Erreur d'allocation mémoire");
        return result;
    }

    b64 = BIO_new(BIO_f_base64());
    bio = BIO_new_mem_buf((void *)input, -1);
    bio = BIO_push(b64, bio);

    BIO_set_flags(bio, BIO_FLAGS_BASE64_NO_NL);
    result->length = BIO_read(bio, result->data, decode_len);

    BIO_free_all(bio);
    
    if (result->length > 0) {
        result->success = 1;
    } else {
        strcpy(result->error_message, "Erreur de décodage base64");
        free(result->data);
        result->data = NULL;
    }

    return result;
}

// Libération mémoire
void free_crypto_result(CryptoResult *result) {
    if (result) {
        if (result->data) {
            free(result->data);
        }
        if (result->error_message) {
            free(result->error_message);
        }
        free(result);
    }
}

// Initialisation OpenSSL
void init_openssl(void) {
    OpenSSL_add_all_algorithms();
}

// Nettoyage OpenSSL
void cleanup_openssl(void) {
    EVP_cleanup();
}
