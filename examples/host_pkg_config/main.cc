#include <cstdio>

#include <zlib.h>

int main() {
    std::printf("zlib version %s\n", zlibVersion());
    return 0;
}
