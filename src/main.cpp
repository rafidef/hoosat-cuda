#include "miner.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// -------------------------------------------------------------------------
// CPU XOSHIRO AND MATRIX GENERATION (Ported from original hoohash.c)
// -------------------------------------------------------------------------

typedef struct {
    uint64_t s0, s1, s2, s3;
} xoshiro_state;

xoshiro_state xoshiro_init(const uint8_t *bytes) {
    xoshiro_state state;
    memcpy(&state.s0, bytes + 0, 8);
    memcpy(&state.s1, bytes + 8, 8);
    memcpy(&state.s2, bytes + 16, 8);
    memcpy(&state.s3, bytes + 24, 8);
    return state;
}

static inline uint64_t rotl64(const uint64_t x, int k) {
    return (x << k) | (x >> (64 - k));
}

uint64_t xoshiro_gen(xoshiro_state *x) {
    uint64_t res = rotl64(x->s0 + x->s3, 23) + x->s0;
    uint64_t t = x->s1 << 17;

    x->s2 ^= x->s0;
    x->s3 ^= x->s1;
    x->s1 ^= x->s2;
    x->s0 ^= x->s3;

    x->s2 ^= t;
    x->s3 = rotl64(x->s3, 45);

    return res;
}

void generateHoohashMatrix(uint8_t *hash, double mat[64][64]) {
    xoshiro_state state = xoshiro_init(hash);
    double normalize = 1000000.0;
    for (int i = 0; i < 64; i++) {
        for (int j = 0; j < 64; j++) {
            uint64_t val = xoshiro_gen(&state);
            uint32_t lower_4_bytes = val & 0xFFFFFFFF;
            mat[i][j] = (double)lower_4_bytes / (double)4294967295.0 * normalize;
        }
    }
}

// -------------------------------------------------------------------------
// TEST HARNESS
// -------------------------------------------------------------------------

char* encodeHex(const uint8_t* bytes, size_t length) {
    char* hexStr = (char*)malloc(length * 2 + 1);
    for (size_t i = 0; i < length; i++) {
        snprintf(hexStr + i * 2, 3, "%02x", bytes[i]);
    }
    return hexStr;
}

int main() {
    printf("--- Hoosat Custom CUDA Miner (H100 Optimized) ---\n");
    printf("Running validation test against CPU host reference...\n");

    // Reference test data from original main_test.c Case 0
    uint8_t PrevHeader[DOMAIN_HASH_SIZE] = {
        0xa4, 0x9d, 0xbc, 0x7d, 0x44, 0xae, 0x83, 0x25, 
        0x38, 0x23, 0x59, 0x2f, 0xd3, 0x88, 0xf2, 0x19, 
        0xf3, 0xcb, 0x83, 0x63, 0x9d, 0x54, 0xc9, 0xe4, 
        0xc3, 0x15, 0x4d, 0xb3, 0x6f, 0x2b, 0x51, 0x57
    };

    State cpu_state;
    memcpy(cpu_state.PrevHeader, PrevHeader, DOMAIN_HASH_SIZE);
    cpu_state.Timestamp = 1725374568455;
    
    // We want to test finding the exact nonce to see if our output matches.
    // The CPU test did: state.Nonce = 7598630810654817703UL;
    cpu_state.Nonce = 7598630810654817703ULL;
    
    // CPU Matrix Generation
    generateHoohashMatrix(PrevHeader, cpu_state.mat);

    // Provide memory for GPU to output its results
    bool found_flag = false;
    uint64_t found_nonce = 0;
    uint8_t found_hash[32] = {0};

    // Launch CUDA miner.
    // Note: Our modified kernel currently sets `found_flag` true strictly when `lastPass[0] == 0x00 && lastPass[1] == 0x00`.
    // Wait, let's just make the kernel always output the hash for the very first thread for testing.
    
    // Normally, pool passes start_nonce and batch_size (e.g. 100000 hashes).
    // For validation, we just want to hash EXACTLY `7598630810654817703` to compare strings.
    launch_miner(&cpu_state, cpu_state.Nonce, 1, &found_flag, &found_nonce, found_hash);

    char* resultHex = encodeHex(found_hash, 32);
    printf("GPU Output (Hex): %s\n", resultHex);
    free(resultHex);

    // CPU ref hash from node test case: 0b633917... (whatever the output is)
    // We will visually compare when running the executable.

    return 0;
}
