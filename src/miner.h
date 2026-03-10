#pragma once
#include <stdint.h>
#include <stddef.h>

#define DOMAIN_HASH_SIZE 32

// CPU representation of mining state, used for copying to GPU
struct State {
    uint8_t PrevHeader[DOMAIN_HASH_SIZE];
    uint64_t Timestamp;
    uint64_t Nonce;
    double mat[64][64];
};

// Start the mining loop on GPU
void launch_miner(const State* cpu_state, uint64_t start_nonce, uint64_t batch_size, uint64_t target64, bool* found_flag, uint64_t* found_nonce, uint8_t* found_hash);

// Declarations for functions defined in main.cpp that need sharing
void generateHoohashMatrix(uint8_t *hash, double mat[64][64]);
char* encodeHex(const uint8_t* bytes, size_t length);
