cmake_minimum_required(VERSION 3.18)
project(hoosat_cuda_miner LANGUAGES C CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)

# Optimize for NVIDIA H100 (sm_90) and RTX 5090 (sm_89)
# We strictly exclude fast math to ensure FP64 IEEE-754 accuracy for the hoohash complex non-linear functions
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -O3 -arch=sm_90 -gencode=arch=compute_89,code=sm_89")

# Add BLAKE3 CPU library from the original node/miner source if available, OR we will implement CUDA-only
include_directories(${CMAKE_SOURCE_DIR}/src)

add_executable(hoosat_miner
    src/main.cpp
    src/stratum.cpp
    src/hoohash_kernel.cu
)

# Link against pthread and potentially others if needed for stratum
target_link_libraries(hoosat_miner pthread)
