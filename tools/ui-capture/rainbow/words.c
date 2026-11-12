#include <stdio.h>

#if defined(LINUX)
#ifdef DEBUG
static int level = 3;
#else
static int level = 1;
#endif
#elif defined(WIN)
static int level = 2;
#else
static int level = 0;
#endif

int main(void) {
    return level;
}
