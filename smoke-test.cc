// Built static and dynamic by the Dockerfile's smoke test.
#include <climits>
#include <cstdio>
#include <link.h>
#include <thread>

static int loaded;

int main() {
  // dl_events_subscribe comes from the patches in patches/. It reports all
  // currently loaded modules before returning.
  if (dl_events_subscribe([](dl_phdr_info*, size_t, void*, int is_unload) {
        if (!is_unload) loaded++;
      }, nullptr) != 0 || loaded == 0) {
    std::puts("dl_events_subscribe failed");
    return 1;
  }
  // PATH_MAX comes from glibc's limits.h, which gcc's limits.h only pulls in
  // when gcc was built seeing glibc's headers (see README).
  std::thread t([] {
    std::printf("hello from glibc c++, PATH_MAX=%d, %d modules loaded\n", PATH_MAX, loaded);
  });
  t.join();
}
