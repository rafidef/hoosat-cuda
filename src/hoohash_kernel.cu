#include "miner.h"
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <math_functions.hpp>
#include <stdio.h>

// -------------------------------------------------------------------------
// CONSTANT MEMORY
// The 64x64 matrix exactly fits in __constant__ memory (32KB). 
// This completely eliminates global VRAM bandwidth lookup bottlenecks.
// -------------------------------------------------------------------------
__constant__ double d_mat[64][64];

// -------------------------------------------------------------------------
// MATH & CONSTANT DEFINITIONS
// -------------------------------------------------------------------------
#define PI 3.14159265358979323846
#define COMPLEX_TRANSFORM_MULTIPLIER 0.000001
#define MULTIPLIER 1234.0
#define DIVIDER 0.0001

// -------------------------------------------------------------------------
// COMPLEX NON-LINEAR FUNCTIONS (Strictly ported from CPU `double` math)
// -------------------------------------------------------------------------

__device__ double MediumComplexNonLinear(double x) {
    return exp(sin(x) + cos(x));
}

__device__ double IntermediateComplexNonLinear(double x) {
    if (x == PI / 2.0 || x == 3.0 * PI / 2.0) {
        return 0; // Avoid singularity
    }
    return sin(x) * sin(x);
}

__device__ double HighComplexNonLinear(double x) {
    return 1.0 / sqrt(fabs(x) + 1.0);
}

__device__ double ComplexNonLinear(double x) {
    double transformFactorOne = (x * COMPLEX_TRANSFORM_MULTIPLIER) / 8.0 - floor((x * COMPLEX_TRANSFORM_MULTIPLIER) / 8.0);
    double transformFactorTwo = (x * COMPLEX_TRANSFORM_MULTIPLIER) / 4.0 - floor((x * COMPLEX_TRANSFORM_MULTIPLIER) / 4.0);

    if (transformFactorOne < 0.33) {
        if (transformFactorTwo < 0.25) {
            return MediumComplexNonLinear(x + (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.5) {
            return MediumComplexNonLinear(x - (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.75) {
            return MediumComplexNonLinear(x * (1.0 + transformFactorTwo));
        } else {
            return MediumComplexNonLinear(x / (1.0 + transformFactorTwo));
        }
    } else if (transformFactorOne < 0.66) {
        if (transformFactorTwo < 0.25) {
            return IntermediateComplexNonLinear(x + (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.5) {
            return IntermediateComplexNonLinear(x - (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.75) {
            return IntermediateComplexNonLinear(x * (1.0 + transformFactorTwo));
        } else {
            return IntermediateComplexNonLinear(x / (1.0 + transformFactorTwo));
        }
    } else {
        if (transformFactorTwo < 0.25) {
            return HighComplexNonLinear(x + (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.5) {
            return HighComplexNonLinear(x - (1.0 + transformFactorTwo));
        } else if (transformFactorTwo < 0.75) {
            return HighComplexNonLinear(x * (1.0 + transformFactorTwo));
        } else {
            return HighComplexNonLinear(x / (1.0 + transformFactorTwo));
        }
    }
}

__device__ double ForComplex(double forComplex) {
    double complex_val;
    double rounds = 1.0;
    complex_val = ComplexNonLinear(forComplex);
    
    // Check for NaN or Inf (standard IEEE-754 rules required here)
    while (isnan(complex_val) || isinf(complex_val)) {
        forComplex = forComplex * 0.1;
        if (forComplex <= 0.0000000000001) {
            return 0.0 * rounds;
        }
        rounds += 1.0;
        complex_val = ComplexNonLinear(forComplex);
    }
    return complex_val * rounds;
}

__device__ double TransformFactor(double x) {
    const double granularity = 1024.0;
    return x / granularity - floor(x / granularity);
}

// -------------------------------------------------------------------------
// HOOHASH KERNEL IMPLEMENTATION
// -------------------------------------------------------------------------
#include "blake3_cuda.cuh"

__device__ void HoohashMatrixMultiplication(const uint8_t hashBytes[32], uint8_t output[32], uint64_t nonce) {
    uint8_t scaledValues[16] = {0}; // 32 values compressed to 16 bytes. Wait, CPU says scaledValues[32], the loop: for (i=0; i<64; i+=2)
    uint8_t vector[64] = {0};
    double product[64] = {0.0};
    uint8_t result[32] = {0};
    
    uint32_t H[8];
    H[0] = ((uint32_t)hashBytes[0] << 24) | ((uint32_t)hashBytes[1] << 16) | ((uint32_t)hashBytes[2] << 8) | hashBytes[3];
    H[1] = ((uint32_t)hashBytes[4] << 24) | ((uint32_t)hashBytes[5] << 16) | ((uint32_t)hashBytes[6] << 8) | hashBytes[7];
    H[2] = ((uint32_t)hashBytes[8] << 24) | ((uint32_t)hashBytes[9] << 16) | ((uint32_t)hashBytes[10] << 8) | hashBytes[11];
    H[3] = ((uint32_t)hashBytes[12] << 24) | ((uint32_t)hashBytes[13] << 16) | ((uint32_t)hashBytes[14] << 8) | hashBytes[15];
    H[4] = ((uint32_t)hashBytes[16] << 24) | ((uint32_t)hashBytes[17] << 16) | ((uint32_t)hashBytes[18] << 8) | hashBytes[19];
    H[5] = ((uint32_t)hashBytes[20] << 24) | ((uint32_t)hashBytes[21] << 16) | ((uint32_t)hashBytes[22] << 8) | hashBytes[23];
    H[6] = ((uint32_t)hashBytes[24] << 24) | ((uint32_t)hashBytes[25] << 16) | ((uint32_t)hashBytes[26] << 8) | hashBytes[27];
    H[7] = ((uint32_t)hashBytes[28] << 24) | ((uint32_t)hashBytes[29] << 16) | ((uint32_t)hashBytes[30] << 8) | hashBytes[31];
    
    double hashMod = (double)(H[0] ^ H[1] ^ H[2] ^ H[3] ^ H[4] ^ H[5] ^ H[6] ^ H[7]);
    double nonceMod = (double)(nonce & 0xFF);
    double sw = 0.0;

    for (int i = 0; i < 32; i++) {
        vector[2 * i] = hashBytes[i] >> 4;
        vector[2 * i + 1] = hashBytes[i] & 0x0F;
    }

    for (int i = 0; i < 64; i++) {
        for (int j = 0; j < 64; j++) {
            if (sw <= 0.02) {
                double input = (d_mat[i][j] * hashMod * (double)vector[j] + nonceMod);
                double out_val = ForComplex(input) * (double)vector[j] * MULTIPLIER;
                product[i] += out_val;
            } else {
                double out_val = d_mat[i][j] * DIVIDER * (double)vector[j];
                product[i] += out_val;
            }
            sw = TransformFactor(product[i]);
        }
    }

    uint8_t scaledValuesFinal[32] = {0};
    for (int i = 0; i < 64; i += 2) {
        uint64_t pval = (uint64_t)product[i] + (uint64_t)product[i + 1];
        scaledValuesFinal[i / 2] = (uint8_t)(pval & 0xFF);
    }

    for (int i = 0; i < 32; i++) {
        result[i] = hashBytes[i] ^ scaledValuesFinal[i];
    }

    blake3_hash_simple(result, 32, output);
}

__global__ void hoohash_miner_kernel(
    const uint8_t* __restrict__ prevHeader, 
    uint64_t timestamp, 
    uint64_t start_nonce, 
    bool* __restrict__ found_flag, 
    uint64_t* __restrict__ found_nonce, 
    uint8_t* __restrict__ found_hash
) {
    uint64_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t thread_nonce = start_nonce + thread_id;

    // Check if another thread already found the nonce to exit early
    if (*found_flag) return;

    // 1. First Blake3 Pass (80 Bytes)
    uint8_t first_input[80];
    for (int i = 0; i < 32; i++) first_input[i] = prevHeader[i];
    
    // Explicit 8-byte little-endian writes for Timestamp and Nonce (to match CPU host representation if it's little-endian)
    uint64_t ts = timestamp;
    for (int i = 0; i < 8; i++) first_input[32 + i] = (uint8_t)(ts >> (i * 8));

    // 32-bytes of zeroes
    for (int i = 0; i < 32; i++) first_input[40 + i] = 0;

    uint64_t nnce = thread_nonce;
    for (int i = 0; i < 8; i++) first_input[72 + i] = (uint8_t)(nnce >> (i * 8));

    uint8_t firstPass[32];
    blake3_hash_simple(first_input, 80, firstPass);

    // 2. Heavy Matrix Multiplication
    uint8_t lastPass[32];
    HoohashMatrixMultiplication(firstPass, lastPass, thread_nonce);

    // 3. Evaluate Target (Assuming target is provided via pool/stratum logic outside. We will check leading zeroes here temporarily as an example)
    // For now, let's just write the result back for validation test. In real miner, it checks network difficulty.
    // We will pass difficulty as another kernel argument in the final phase, but right now we capture all for testing or target matches.
    
    // Dummy check: e.g. finding 2 leading zero bytes.
    // For validation phase, we forcibly write the hash out if thread_id == 0
    // so we can compare it byte against byte with the CPU test cases.
    if (thread_id == 0 || (lastPass[0] == 0x00 && lastPass[1] == 0x00)) {
        if (atomicExch((int*)found_flag, 1) == 0) {
            *found_nonce = thread_nonce;
            for(int i = 0; i < 32; i++) found_hash[i] = lastPass[i];
        }
    }
}

// -------------------------------------------------------------------------
// CPU LAUNCHER WRAPPER
// -------------------------------------------------------------------------
void launch_miner(const State* cpu_state, uint64_t start_nonce, uint64_t batch_size, bool* found_flag, uint64_t* found_nonce, uint8_t* found_hash) {
    // Copy Matrix to __constant__ memory
    cudaMemcpyToSymbol(d_mat, cpu_state->mat, sizeof(double) * 64 * 64);
    
    // Allocate device status variables
    bool* d_found_flag;
    uint64_t* d_found_nonce;
    uint8_t* d_found_hash;
    uint8_t* d_prevHeader;

    cudaMalloc(&d_found_flag, sizeof(bool));
    cudaMalloc(&d_found_nonce, sizeof(uint64_t));
    cudaMalloc(&d_found_hash, 32);
    cudaMalloc(&d_prevHeader, 32);

    cudaMemcpy(d_found_flag, found_flag, sizeof(bool), cudaMemcpyHostToDevice);
    cudaMemcpy(d_prevHeader, cpu_state->PrevHeader, 32, cudaMemcpyHostToDevice);

    int threadsPerBlock = 256;
    int blocksPerGrid = (batch_size + threadsPerBlock - 1) / threadsPerBlock;

    hoohash_miner_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        d_prevHeader,
        cpu_state->Timestamp,
        start_nonce,
        d_found_flag,
        d_found_nonce,
        d_found_hash
    );

    cudaDeviceSynchronize();

    cudaMemcpy(found_flag, d_found_flag, sizeof(bool), cudaMemcpyDeviceToHost);
    cudaMemcpy(found_nonce, d_found_nonce, sizeof(uint64_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(found_hash, d_found_hash, 32, cudaMemcpyDeviceToHost);

    cudaFree(d_found_flag);
    cudaFree(d_found_nonce);
    cudaFree(d_found_hash);
    cudaFree(d_prevHeader);
}
