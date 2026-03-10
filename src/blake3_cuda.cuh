#pragma once
#include <stdint.h>
#include <cuda_runtime.h>
#include <string.h>

#define BLAKE3_BLOCK_LEN 64
#define BLAKE3_KEY_LEN 32
#define BLAKE3_OUT_LEN 32

__constant__ static const uint32_t BLAKE3_IV[8] = {
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
};

__constant__ static const uint8_t BLAKE3_MSG_SCHEDULE[7][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 11, 5, 0, 9, 15, 8, 1},
    {10, 7, 12, 5, 14, 3, 13, 15, 4, 11, 0, 2, 9, 8, 1, 6},
    {12, 13, 5, 0, 15, 10, 14, 8, 7, 11, 2, 3, 9, 1, 6, 4},
    {5, 14, 0, 2, 8, 12, 15, 1, 13, 11, 3, 10, 9, 6, 4, 7},
    {0, 15, 2, 3, 1, 5, 8, 6, 14, 11, 10, 12, 9, 4, 7, 13},
};

// Flags
#define BLAKE3_FLAG_CHUNK_START         (1 << 0)
#define BLAKE3_FLAG_CHUNK_END           (1 << 1)
#define BLAKE3_FLAG_PARENT              (1 << 2)
#define BLAKE3_FLAG_ROOT                (1 << 3)

__device__ __forceinline__ uint32_t rotr32(uint32_t w, uint32_t c) {
    return (w >> c) | (w << (32 - c));
}

__device__ __forceinline__ void g(uint32_t *state, size_t a, size_t b, size_t c, size_t d, uint32_t x, uint32_t y) {
    state[a] = state[a] + state[b] + x;
    state[d] = rotr32(state[d] ^ state[a], 16);
    state[c] = state[c] + state[d];
    state[b] = rotr32(state[b] ^ state[c], 12);
    state[a] = state[a] + state[b] + y;
    state[d] = rotr32(state[d] ^ state[a], 8);
    state[c] = state[c] + state[d];
    state[b] = rotr32(state[b] ^ state[c], 7);
}

__device__ __forceinline__ void round_fn(uint32_t state[16], const uint32_t *msg, size_t round) {
    const uint8_t *schedule = BLAKE3_MSG_SCHEDULE[round];
    g(state, 0, 4, 8, 12, msg[schedule[0]], msg[schedule[1]]);
    g(state, 1, 5, 9, 13, msg[schedule[2]], msg[schedule[3]]);
    g(state, 2, 6, 10, 14, msg[schedule[4]], msg[schedule[5]]);
    g(state, 3, 7, 11, 15, msg[schedule[6]], msg[schedule[7]]);
    g(state, 0, 5, 10, 15, msg[schedule[8]], msg[schedule[9]]);
    g(state, 1, 6, 11, 12, msg[schedule[10]], msg[schedule[11]]);
    g(state, 2, 7, 8, 13, msg[schedule[12]], msg[schedule[13]]);
    g(state, 3, 4, 9, 14, msg[schedule[14]], msg[schedule[15]]);
}

__device__ __forceinline__ void blake3_compress(uint32_t cv[8], const uint8_t block[BLAKE3_BLOCK_LEN], uint8_t block_len, uint64_t counter, uint8_t flags) {
    uint32_t state[16];
    uint32_t block_words[16];

    for (int i = 0; i < 16; i++) {
        block_words[i] = ((uint32_t)block[i*4 + 0] ) |
                         ((uint32_t)block[i*4 + 1] << 8) |
                         ((uint32_t)block[i*4 + 2] << 16) |
                         ((uint32_t)block[i*4 + 3] << 24);
    }

    state[0] = cv[0];
    state[1] = cv[1];
    state[2] = cv[2];
    state[3] = cv[3];
    state[4] = cv[4];
    state[5] = cv[5];
    state[6] = cv[6];
    state[7] = cv[7];
    state[8] = BLAKE3_IV[0];
    state[9] = BLAKE3_IV[1];
    state[10] = BLAKE3_IV[2];
    state[11] = BLAKE3_IV[3];
    state[12] = (uint32_t)counter;
    state[13] = (uint32_t)(counter >> 32);
    state[14] = (uint32_t)block_len;
    state[15] = (uint32_t)flags;

    #pragma unroll
    for (int r = 0; r < 7; r++) {
        round_fn(state, block_words, r);
    }

    for(int i = 0; i < 8; i++) {
        cv[i] = state[i] ^ state[i + 8];
    }
}

// A simplified direct hashing function specifically tailored to block size maximum constraints (up to 128 bytes, meaning 1-2 chunks)
// Hashing an array under 1024 bytes (1 single chunk), requires NO parent nodes in the Merkle tree, just consecutive compressions.
__device__ __forceinline__ void blake3_hash_simple(const uint8_t *input, size_t input_len, uint8_t out[32]) {
    uint32_t cv[8];
    for (int i=0; i<8; i++) cv[i] = BLAKE3_IV[i];

    uint8_t block[BLAKE3_BLOCK_LEN];
    size_t offset = 0;
    
    // We only ever hash exactly 80 or 32 bytes in Hoosat proof of work. 
    // This implies blocks will be at most 2.
    while (offset < input_len) {
        size_t block_len = input_len - offset;
        uint8_t flags = BLAKE3_FLAG_CHUNK_START;
        
        if (block_len > BLAKE3_BLOCK_LEN) {
            block_len = BLAKE3_BLOCK_LEN;
            flags = (offset == 0) ? BLAKE3_FLAG_CHUNK_START : 0;
        } else {
            // Last block
            flags = (offset == 0) ? BLAKE3_FLAG_CHUNK_START : 0;
            flags |= BLAKE3_FLAG_CHUNK_END;
            flags |= BLAKE3_FLAG_ROOT;
        }

        memset(block, 0, BLAKE3_BLOCK_LEN);
        memcpy(block, input + offset, block_len);

        blake3_compress(cv, block, (uint8_t)block_len, 0, flags);
        offset += block_len;
    }

    for (int i = 0; i < 8; i++) {
        out[i*4 + 0] = (uint8_t)(cv[i]);
        out[i*4 + 1] = (uint8_t)(cv[i] >> 8);
        out[i*4 + 2] = (uint8_t)(cv[i] >> 16);
        out[i*4 + 3] = (uint8_t)(cv[i] >> 24);
    }
}
