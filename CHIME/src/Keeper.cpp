#include "Keeper.h"
#include <fstream>
#include <string>
#include <iostream>
#include <random>
#include <cstdlib>   // getenv / atoi for CHIME_NODE_ID role pinning

char *getIP();

std::string trim(const std::string &s) {
  std::string res = s;
  if (!res.empty()) {
    res.erase(0, res.find_first_not_of(" "));
    res.erase(res.find_last_not_of(" ") + 1);
  }
  return res;
}

const char *Keeper::SERVER_NUM_KEY = "serverNum";

Keeper::Keeper(uint32_t maxServer)
    : maxServer(maxServer), curServer(0), memc(NULL) {}

Keeper::~Keeper() {
  //   listener.detach();

  disconnectMemcached();
}

bool Keeper::connectMemcached() {
  memcached_server_st *servers = NULL;
  memcached_return rc;

  std::ifstream conf("../memcached.conf");

  if (!conf) {
    fprintf(stderr, "can't open memcached.conf\n");
    return false;
  }

  std::string addr, port;
  std::getline(conf, addr);
  std::getline(conf, port);

  memc = memcached_create(NULL);
  servers = memcached_server_list_append(servers, trim(addr).c_str(),
                                         std::stoi(trim(port)), &rc);
  rc = memcached_server_push(memc, servers);

  if (rc != MEMCACHED_SUCCESS) {
    fprintf(stderr, "Counld't add server:%s\n", memcached_strerror(memc, rc));
    sleep(1);
    return false;
  }

  memcached_behavior_set(memc, MEMCACHED_BEHAVIOR_BINARY_PROTOCOL, 1);
  return true;
}

bool Keeper::disconnectMemcached() {
  if (memc) {
    memcached_quit(memc);
    memcached_free(memc);
    memc = NULL;
  }
  return true;
}

void Keeper::serverEnter() {
  memcached_return rc;
  uint64_t serverNum;

  while (true) {
    rc = memcached_increment(memc, SERVER_NUM_KEY, strlen(SERVER_NUM_KEY), 1,
                             &serverNum);
    if (rc == MEMCACHED_SUCCESS) {
      std::string ip(getIP());
#ifdef STATIC_ID_FROM_IP
      myNodeID = std::atoi(ip.substr(ip.find_last_of('.') + 1).c_str()) - 1;
#else
      // Deterministic role pinning: CHIME_NODE_ID fixes this process's node id
      // regardless of memcached registration order, so the memory node is ALWAYS
      // node 0 (MN, owns the DSM + dir-threads) and the compute node ALWAYS node
      // 1 (CN). The atomic increment above still ran, so the serverConnect()
      // barrier (serverNum == maxServer) is unaffected -- only the id is pinned.
      // Without it the id falls back to registration order (serverNum - 1), a
      // timing race that can SWAP the two roles between rounds; different-node
      // binaries then disagree on the DSM layout and every WR flushes with a
      // garbage completion status.
      const char *envId = getenv("CHIME_NODE_ID");
      if (envId && *envId) {
        myNodeID = static_cast<uint16_t>(std::atoi(envId));
      } else {
        myNodeID = serverNum - 1;
      }
#endif
      Debug::notifyInfo("Compute server %d start up [%s]\n", myNodeID, ip.c_str());
      return;
    }
    fprintf(stderr, "Server %d Counld't incr value and get ID: %s, retry...\n",
            myNodeID, memcached_strerror(memc, rc));
    usleep(10000);
  }
}

void Keeper::serverConnect() {

  size_t l;
  uint32_t flags;
  memcached_return rc;

  while (curServer < maxServer) {
    char *serverNumStr = memcached_get(memc, SERVER_NUM_KEY,
                                       strlen(SERVER_NUM_KEY), &l, &flags, &rc);
    if (rc != MEMCACHED_SUCCESS) {
      fprintf(stderr, "Server %d Counld't get serverNum: %s, retry\n", myNodeID,
              memcached_strerror(memc, rc));
      continue;
    }
    uint32_t serverNum = atoi(serverNumStr);
    free(serverNumStr);

    // /connect server K
    for (size_t k = curServer; k < serverNum; ++k) {
      if (k != myNodeID) {
        connectNode(k);
        printf("I connect server %zu\n", k);
      }
    }
    curServer = serverNum;
  }
}

void Keeper::memSet(const char *key, uint32_t klen, const char *val,
                    uint32_t vlen) {

  memcached_return rc;
  while (true) {
    rc = memcached_set(memc, key, klen, val, vlen, (time_t)0, (uint32_t)0);
    if (rc == MEMCACHED_SUCCESS) {
      break;
    }
    usleep(400);
  }
}

char *Keeper::memGet(const char *key, uint32_t klen, size_t *v_size) {

  size_t l;
  char *res;
  uint32_t flags;
  memcached_return rc;

  while (true) {

    res = memcached_get(memc, key, klen, &l, &flags, &rc);
    if (rc == MEMCACHED_SUCCESS) {
      break;
    }
    usleep(40 * myNodeID);
  }

  if (v_size != nullptr) {
    *v_size = l;
  }
  
  return res;
}

uint64_t Keeper::memFetchAndAdd(const char *key, uint32_t klen) {
  uint64_t res;
  while (true) {
    memcached_return rc = memcached_increment(memc, key, klen, 1, &res);
    if (rc == MEMCACHED_SUCCESS) {
      return res;
    }
    usleep(400 * myNodeID);
  }
}
