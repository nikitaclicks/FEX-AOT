#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t mix(uint64_t x) {
  x ^= x >> 30;
  x *= 0xbf58476d1ce4e5b9ULL;
  x ^= x >> 27;
  x *= 0x94d049bb133111ebULL;
  x ^= x >> 31;
  return x;
}

int main(int argc, char** argv) {
  uint64_t seed = 0x1234abcddcba4321ULL;
  if (argc > 1) {
    seed = strtoull(argv[1], NULL, 0);
  }

  uint64_t state = seed;
  uint64_t checksum = 0;

  for (uint64_t i = 0; i < 200000; ++i) {
    uint64_t branch = (state ^ i) & 7;
    if (branch < 2) {
      state = mix(state + 0x9e3779b97f4a7c15ULL + i);
    } else if (branch < 5) {
      state = (state << 13) ^ (state >> 7) ^ (i * 0x5851f42d4c957f2dULL);
      state = mix(state);
    } else {
      state ^= (state << 17);
      state ^= (state >> 9);
      state ^= (i + 0x27d4eb2f165667c5ULL);
    }

    if ((state & 0xff) == 0x5a) {
      checksum ^= mix(state + i);
    } else {
      checksum += state ^ (i * 3);
    }
  }

  uint32_t signature = (uint32_t)(checksum ^ (checksum >> 32) ^ state);
  printf("AOT_CANARY seed=%llu signature=%08x\n", (unsigned long long)seed, signature);

  return 0;
}