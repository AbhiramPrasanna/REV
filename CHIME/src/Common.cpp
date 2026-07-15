#include "Common.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <net/if.h>
#include <unistd.h>
#include <arpa/inet.h>

void bindCore(uint16_t core) {
    // CHIME's callers derive core ids from the compile-time CPU_PHYSICAL_CORE_NUM
    // (e.g. Directory::dirThread does (CPU_PHYSICAL_CORE_NUM-1-dirID)*2+1), which
    // is 72 by default and therefore asks for cores 137..143. On a machine with
    // fewer cores every one of those binds fails, the thread silently runs
    // UNPINNED, and we lose the NUMA/core locality the whole design assumes --
    // announced only by a stream of "can't bind core!". Wrap into the range that
    // actually exists so the pinning stays valid on any core count.
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n > 0 && core >= n) core = (uint16_t)(core % n);

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core, &cpuset);
    int rc = pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    if (rc != 0) {
        Debug::notifyError("can't bind core!");
    }
}

char *getIP() {
    struct ifreq ifr;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);

    ifr.ifr_addr.sa_family = AF_INET;
    strncpy(ifr.ifr_name, NET_DEV_NAME, IFNAMSIZ - 1);

    ioctl(fd, SIOCGIFADDR, &ifr);
    close(fd);

    return inet_ntoa(((struct sockaddr_in*)&ifr.ifr_addr)->sin_addr);
}

char *getMac() {
    static struct ifreq ifr;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);

    ifr.ifr_addr.sa_family = AF_INET;
    strncpy(ifr.ifr_name, "ens2", IFNAMSIZ - 1);

    ioctl(fd, SIOCGIFHWADDR, &ifr);
    close(fd);

    return (char *)ifr.ifr_hwaddr.sa_data;
}
