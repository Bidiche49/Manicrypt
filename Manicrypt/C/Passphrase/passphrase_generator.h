//
//  passphrase_generator.h
//  Manicrypt
//
//  Générateur de passphrases sécurisé en C pur
//

#ifndef passphrase_generator_h
#define passphrase_generator_h

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <openssl/rand.h>
#include <ctype.h>
#include <math.h>
#include <sys/mman.h>

#include "../Utils/utils.h"

// Constantes
#define WORDLIST_SIZE 7777
#define MAX_WORD_LENGTH 10
#define MIN_WORD_LENGTH 3
#define MAX_PASSPHRASE_LENGTH 512
#define MAX_WORDS 15

// Options de génération
typedef struct {
    int word_count;        // Nombre de mots (4, 5, 7, 10, ou 15)
    bool capitalize_word;  // Capitaliser un mot aléatoire
    bool add_digit;       // Ajouter un chiffre
    bool add_symbol;      // Ajouter un symbole
} PassphraseOptions;

// Résultat de génération
typedef struct {
    char* passphrase;     // Passphrase générée (allouée dynamiquement)
    size_t length;        // Longueur de la passphrase
    double entropy_bits;  // Entropie en bits
    int success;          // 1 = succès, 0 = échec
    char* error_message;  // Message d'erreur si échec
} PassphraseResult;

// Fonctions principales
PassphraseResult* generate_passphrase(const PassphraseOptions* options);
void free_passphrase_result(PassphraseResult* result);

// Fonctions utilitaires
double calculate_entropy(const PassphraseOptions* options);
const char* get_security_rating(double entropy_bits);
int validate_options(const PassphraseOptions* options);

// Chargement de la wordlist
int load_eff_wordlist(const char* filepath);
void cleanup_wordlist(void);

// Générateur cryptographiquement sûr
int secure_random_range(int min, int max);

#endif /* passphrase_generator_h */
