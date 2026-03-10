#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <chrono>
#include <atomic>
#include <iomanip>
#include <sstream>
#include <sys/types.h>

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <netdb.h>
#endif

#include "miner.h"
#include "json.hpp" // nlohmann/json

using json = nlohmann::json;

class StratumClient {
private:
    std::string host;
    int port;
    std::string wallet;
    std::string password;
#ifdef _WIN32
    SOCKET sock;
#else
    int sock;
#endif

    std::mutex net_mutex;
    bool connected;
    std::atomic<uint64_t> total_hashes;
    bool is_mining;
    
    // Mining state
    State global_state;
    std::string current_job_id;
    std::mutex state_mutex;
    bool job_ready;
    uint32_t rpc_id;

public:
    StratumClient(std::string h, int p, std::string w, std::string pass) 
        : host(h), port(p), wallet(w), password(pass), connected(false), total_hashes(0), is_mining(false), job_ready(false), rpc_id(10) {
#ifdef _WIN32
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif
    }

    ~StratumClient() {
        disconnect();
#ifdef _WIN32
        WSACleanup();
#endif
    }

    bool connectToPool() {
        {
            std::lock_guard<std::mutex> lock(net_mutex);
            
            sock = socket(AF_INET, SOCK_STREAM, 0);
#ifdef _WIN32
            if (sock == INVALID_SOCKET) return false;
#else
            if (sock < 0) return false;
#endif

            struct sockaddr_in serv_addr;
            serv_addr.sin_family = AF_INET;
            serv_addr.sin_port = htons(port);
            
            struct hostent *he = gethostbyname(host.c_str());
            if (he == NULL) {
                std::cerr << "Failed to resolve host." << std::endl;
                return false;
            }
            struct in_addr **addr_list = (struct in_addr **) he->h_addr_list;
            serv_addr.sin_addr = *addr_list[0];

            if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
                std::cerr << "Failed to connect to pool: " << host << ":" << port << std::endl;
                return false;
            }

            connected = true;
        } // Unlock net_mutex before calling sendLine

        std::cout << "Connected to stratum pool." << std::endl;
        
        // Send initial protocol messages
        sendLine("{\"id\": 1, \"method\": \"mining.subscribe\", \"params\": [\"Hoosat-H100/1.0\"]}");
        return true;
    }

    void disconnect() {
        if (connected) {
#ifdef _WIN32
            closesocket(sock);
#else
            close(sock);
#endif
            connected = false;
        }
    }

    void sendLine(const std::string& line) {
        if (!connected) return;
        std::string payload = line + "\n";
        std::lock_guard<std::mutex> lock(net_mutex);
        send(sock, payload.c_str(), payload.size(), 0);
    }

    void authorize() {
        std::string payload = "{\"id\": 2, \"method\": \"mining.authorize\", \"params\": [\"" + wallet + "\", \"" + password + "\"]}";
        sendLine(payload);
    }
    
    void submitShare(const std::string& job, uint64_t nonce) {
        uint32_t current_id = rpc_id++;
        json j;
        j["id"] = current_id;
        j["method"] = "mining.submit";
        j["params"] = {wallet, job, nonce};
        sendLine(j.dump());
        std::cout << "\n[MINER] >> Submitted Share [Nonce: " << nonce << "] for Job " << job << "!" << std::endl;
    }

    // Dedicated thread to calculate and display hashrate every few seconds
    void hashrateLoop() {
        auto last_time = std::chrono::steady_clock::now();
        uint64_t last_hashes = 0;

        while (is_mining) {
            std::this_thread::sleep_for(std::chrono::seconds(5));
            auto current_time = std::chrono::steady_clock::now();
            
            uint64_t current_hashes = total_hashes.load();
            uint64_t hashes_since_last = current_hashes - last_hashes;
            
            double seconds = std::chrono::duration<double>(current_time - last_time).count();
            double hashes_per_second = hashes_since_last / seconds;

            std::cout << "\r[MINER] Speed: " 
                      << std::fixed << std::setprecision(2) << (hashes_per_second / 1000.0) 
                      << " kH/s (" << (hashes_per_second / 1000000.0) << " MH/s)        " 
                      << std::flush;

            last_hashes = current_hashes;
            last_time = current_time;
        }
    }

    void gpuMiningLoop() {
        State local_state;
        std::string local_job;
        uint64_t current_nonce = 0;
        
        while (is_mining) {
            if (!job_ready) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }

            // Lock and copy the latest job broadcasted by pool
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                local_state = global_state;
                local_job = current_job_id;
            }

            bool found_flag = false;
            uint64_t found_nonce = 0;
            uint8_t found_hash[32] = {0};
            uint64_t batch_size = 500000; // Optimal batch size for H100
            
            // Execute the CUDA Kernel!
            launch_miner(&local_state, current_nonce, batch_size, &found_flag, &found_nonce, found_hash);
            
            total_hashes += batch_size;
            current_nonce += batch_size;
            
            if (found_flag) {
                // A share met the difficulty! Submit it to pool
                submitShare(local_job, found_nonce);
            }
        }
    }

    // Runs in the main thread parsing incoming JSON for `mining.notify`.
    void listenLoop() {
        char buffer[16384];
        std::string overflow = "";

        is_mining = true;
        std::thread hrThread(&StratumClient::hashrateLoop, this);
        std::thread gpuThread(&StratumClient::gpuMiningLoop, this);

        while (connected) {
            int bytes_read = recv(sock, buffer, sizeof(buffer) - 1, 0);
            if (bytes_read <= 0) {
                std::cout << "\nConnection dropped by pool." << std::endl;
                disconnect();
                break;
            }
            buffer[bytes_read] = '\0';
            std::string msg = overflow + std::string(buffer);
            overflow = "";

            size_t pos = 0;
            while ((pos = msg.find('\n')) != std::string::npos) {
                std::string line = msg.substr(0, pos);
                msg.erase(0, pos + 1);

                if (line.empty()) continue;

                try {
                    json j = json::parse(line);
                    
                    if (j.contains("method") && j["method"] == "mining.notify") {
                        auto params = j["params"];
                        std::string job_id = params[0].get<std::string>();
                        auto prev_u64 = params[1].get<std::vector<uint64_t>>();
                        uint64_t timestamp = params[2].get<uint64_t>();

                        std::lock_guard<std::mutex> lock(state_mutex);
                        current_job_id = job_id;
                        global_state.Timestamp = timestamp;
                        
                        // Parse PrevHeader (4 x uint64_t)
                        for (int i=0; i<4; i++) {
                            uint64_t v = prev_u64[i];
                            memcpy(&global_state.PrevHeader[i*8], &v, 8);
                        }

                        std::cout << "\n[POOL] Received new job: " << job_id << std::endl;

                        // Generate the CPU heavy Matrix
                        generateHoohashMatrix(global_state.PrevHeader, global_state.mat);
                        job_ready = true;
                    } 
                    else if (j.contains("result") && j.contains("id")) {
                        if (j["result"] == true) {
                            // std::cout << "\n[POOL] Accept response received." << std::endl;
                        }
                    }
                    else if (j.contains("method") && j["method"] == "mining.set_difficulty") {
                        std::cout << "\n[POOL] Difficulty updated to: " << j["params"][0] << std::endl;
                    }
                } catch (const std::exception& e) {
                    std::cerr << "\n[JSON ERROR] " << e.what() << " on line: " << line << std::endl;
                    overflow = line;
                }
            }
            if (!msg.empty()) {
                overflow = msg;
            }
        }

        is_mining = false;
        if (hrThread.joinable()) hrThread.join();
        if (gpuThread.joinable()) gpuThread.join();
    }
};

// Start point if building as a standalone executable
int main(int argc, char** argv) {
    StratumClient client("118.93.38.187", 5555, "hoosat:qypkv9wz8y9254xw3kr9u98h2eqqsekhcayjvrdtkrvdr4ztfj549fcyxmkr522", "x");
    if (client.connectToPool()) {
        client.authorize();
        client.listenLoop();
    }
    return 0;
}
