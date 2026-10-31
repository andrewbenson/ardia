#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXS 4000
#define MAXF 96
static uint64_t g_t[MAXS];
static int g_state[MAXS], g_n[MAXS];
static uint64_t g_f[MAXS][MAXF];
static int g_count;
static thread_t g_main;
static uint64_t g_t0;
static int g_ms;

static int readptr(uint64_t addr, uint64_t *out) {
  mach_vm_size_t got = 0;
  extern kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
  return mach_vm_read_overwrite(mach_task_self(), addr, 8, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == 8;
}

static void *sampler(void *arg) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  const uint64_t end = g_t0 + (uint64_t)g_ms * 1000000ull * tb.denom / tb.numer;
  while (mach_absolute_time() < end && g_count < MAXS) {
    const int i = g_count;
    if (thread_suspend(g_main) != KERN_SUCCESS) break;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    struct thread_basic_info bi;
    mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
    thread_info(g_main, THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt);
    g_state[i] = bi.run_state;
    int n = 0;
    if (thread_get_state(g_main, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
      g_f[i][n++] = __darwin_arm_thread_state64_get_pc(st) & 0x0000000fffffffffull;
      g_f[i][n++] = __darwin_arm_thread_state64_get_lr(st) & 0x0000000fffffffffull;
      uint64_t fp = __darwin_arm_thread_state64_get_fp(st);
      while (fp && n < MAXF) {
        uint64_t next, ret;
        if (!readptr(fp, &next) || !readptr(fp + 8, &ret)) break;
        ret &= 0x0000000fffffffffull;
        if (!ret) break;
        g_f[i][n++] = ret;
        if (next <= fp) break;
        fp = next;
      }
    }
    thread_resume(g_main);
    g_n[i] = n;
    g_t[i] = (mach_absolute_time() - g_t0) * tb.numer / tb.denom / 1000;
    g_count++;
    usleep(900);
  }
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (!dir) return NULL;
  char path[2048];
  snprintf(path, sizeof path, "%s/acsample.txt", dir);
  FILE *f = fopen(path, "w");
  if (!f) return NULL;
  fprintf(f, "t0abs %llu\n", (unsigned long long)(g_t0 * tb.numer / tb.denom / 1000));
  for (uint32_t k = 0; k < _dyld_image_count(); k++)
    fprintf(f, "img %llx %s\n", (unsigned long long)(uintptr_t)_dyld_get_image_header(k), _dyld_get_image_name(k));
  for (int i = 0; i < g_count; i++) {
    fprintf(f, "s %llu %d", (unsigned long long)g_t[i], g_state[i]);
    for (int k = 0; k < g_n[i]; k++) fprintf(f, " %llx", (unsigned long long)g_f[i][k]);
    fputc('\n', f);
  }
  static uint64_t seen[200000];
  int nseen = 0;
  for (int i = 0; i < g_count; i++)
    for (int k = 0; k < g_n[i]; k++) {
      const uint64_t pc = g_f[i][k];
      int dup = 0;
      for (int j = 0; j < nseen; j++)
        if (seen[j] == pc) { dup = 1; break; }
      if (dup || nseen >= 200000) continue;
      seen[nseen++] = pc;
      Dl_info info;
      if (dladdr((void *)(uintptr_t)(k ? pc - 1 : pc), &info) && info.dli_fname)
        fprintf(f, "sym %llx %llx %s\t%s\n", (unsigned long long)pc, (unsigned long long)(uintptr_t)info.dli_fbase,
                info.dli_fname, info.dli_sname ? info.dli_sname : "?");
    }
  fclose(f);
  return NULL;
}

static _Atomic unsigned long g_iter;
static _Atomic int g_inIter;
static _Atomic uint64_t g_iterStartUs;
#define DONE_RING 4096
static _Atomic uint64_t g_doneIter[DONE_RING], g_doneDurUs[DONE_RING];

static uint64_t epoch_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static void loop_activity(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
  if (activity == kCFRunLoopAfterWaiting) {
    atomic_store(&g_iterStartUs, epoch_us());
    atomic_fetch_add(&g_iter, 1);
    atomic_store(&g_inIter, 1);
  } else if (atomic_load(&g_inIter)) {
    const unsigned long it = atomic_load(&g_iter);
    atomic_store(&g_doneDurUs[it % DONE_RING], epoch_us() - atomic_load(&g_iterStartUs));
    atomic_store(&g_doneIter[it % DONE_RING], it);
    atomic_store(&g_inIter, 0);
  }
}

#define BUF 3000
static uint64_t b_t[BUF], b_f[BUF][MAXF];
static int b_state[BUF], b_n[BUF], b_count, b_dropped;
static unsigned long b_iter;
static uint64_t b_iterStart;
static FILE *g_out;
static uint32_t g_images;
#define SEEN_SLOTS (1 << 20)
static uint64_t *g_seen;
static int g_nseen;
#define MAXSEEN (SEEN_SLOTS / 2)

static int seen_before(uint64_t pc) {
  uint64_t key = pc + 1;
  size_t i = (size_t)((key * 0x9E3779B97F4A7C15ull) >> 44) & (SEEN_SLOTS - 1);
  for (;;) {
    if (g_seen[i] == key) return 1;
    if (!g_seen[i]) {
      if (g_nseen >= MAXSEEN) return 1;
      g_seen[i] = key;
      g_nseen++;
      return 0;
    }
    i = (i + 1) & (SEEN_SLOTS - 1);
  }
}

static void write_images(void) {
  const uint32_t n = _dyld_image_count();
  for (; g_images < n; g_images++)
    fprintf(g_out, "img %llx %s\n", (unsigned long long)(uintptr_t)_dyld_get_image_header(g_images), _dyld_get_image_name(g_images));
}

static void write_syms(int i) {
  for (int k = 0; k < b_n[i]; k++) {
    const uint64_t pc = b_f[i][k];
    if (seen_before(pc)) continue;
    Dl_info info;
    if (dladdr((void *)(uintptr_t)(k ? pc - 1 : pc), &info) && info.dli_fname)
      fprintf(g_out, "sym %llx %llx %s\t%s\n", (unsigned long long)pc, (unsigned long long)(uintptr_t)info.dli_fbase, info.dli_fname,
              info.dli_sname ? info.dli_sname : "?");
  }
}

static void flush_iteration(const char *scenario, uint64_t durUs, int open) {
  if (!b_count) return;
  write_images();
  fprintf(g_out, "it %s\t%llu %llu %d %d %d\n", scenario, (unsigned long long)b_iterStart, (unsigned long long)durUs, b_count, b_dropped, open);
  for (int i = 0; i < b_count; i++) {
    fprintf(g_out, "s %llu %d", (unsigned long long)b_t[i], b_state[i]);
    for (int k = 0; k < b_n[i]; k++) fprintf(g_out, " %llx", (unsigned long long)b_f[i][k]);
    fputc('\n', g_out);
  }
  for (int i = 0; i < b_count; i++) write_syms(i);
  fflush(g_out);
}

static void end_buffer(const char *scenario, int open) {
  uint64_t dur = 0;
  if (open) {
    dur = epoch_us() - b_iterStart;
  } else if (atomic_load(&g_doneIter[b_iter % DONE_RING]) == b_iter) {
    dur = atomic_load(&g_doneDurUs[b_iter % DONE_RING]);
  }
  if (dur >= 50000) flush_iteration(scenario, dur, open);
  b_count = 0;
  b_dropped = 0;
}

static int read_arm(const char *path, char *scenario, size_t size) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  const size_t n = fread(scenario, 1, size - 1, f);
  fclose(f);
  scenario[n] = 0;
  for (char *c = scenario; *c; c++)
    if (*c == '\n' || *c == '\t') *c = ' ';
  return n > 0;
}

static void *scenario_sampler(void *arg) {
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (!dir) return NULL;
  char arm[2048], out[2048], scenario[256] = {0}, armed[256] = {0};
  snprintf(arm, sizeof arm, "%s/acsample-arm", dir);
  snprintf(out, sizeof out, "%s/acsample-stalls.txt", dir);
  g_seen = calloc(SEEN_SLOTS, sizeof *g_seen);
  if (!g_seen) return NULL;
  int on = 0;
  unsigned long polls = 0;
  for (;;) {
    if (!on || ++polls % 10 == 0) {
      const int now = read_arm(arm, scenario, sizeof scenario);
      if (now && (!on || strcmp(scenario, armed) != 0)) {
        if (on) end_buffer(armed, 1);
        if (!g_out) {
          g_out = fopen(out, "a");
          if (!g_out) return NULL;
          fprintf(g_out, "pid %d\n", getpid());
        }
        strcpy(armed, scenario);
        on = 1;
      } else if (!now && on) {
        end_buffer(armed, 1);
        on = 0;
      }
    }
    if (!on) {
      usleep(20000);
      continue;
    }
    const int inIter = atomic_load(&g_inIter);
    const unsigned long it = atomic_load(&g_iter);
    if (b_count && (it != b_iter || !inIter)) end_buffer(armed, 0);
    if (!inIter) {
      usleep(900);
      continue;
    }
    const uint64_t iterStart = atomic_load(&g_iterStartUs);
    if (epoch_us() - iterStart < 16000) {
      usleep(900);
      continue;
    }
    if (!b_count) {
      b_iter = it;
      b_iterStart = iterStart;
    }
    if (b_count >= BUF) {
      b_dropped++;
      usleep(900);
      continue;
    }
    const int i = b_count;
    if (thread_suspend(g_main) != KERN_SUCCESS) break;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    struct thread_basic_info bi;
    mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
    thread_info(g_main, THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt);
    b_state[i] = bi.run_state;
    int n = 0;
    if (thread_get_state(g_main, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
      b_f[i][n++] = __darwin_arm_thread_state64_get_pc(st) & 0x0000000fffffffffull;
      b_f[i][n++] = __darwin_arm_thread_state64_get_lr(st) & 0x0000000fffffffffull;
      uint64_t fp = __darwin_arm_thread_state64_get_fp(st);
      while (fp && n < MAXF) {
        uint64_t next, ret;
        if (!readptr(fp, &next) || !readptr(fp + 8, &ret)) break;
        ret &= 0x0000000fffffffffull;
        if (!ret) break;
        b_f[i][n++] = ret;
        if (next <= fp) break;
        fp = next;
      }
    }
    thread_resume(g_main);
    b_n[i] = n;
    b_t[i] = epoch_us();
    if (atomic_load(&g_iter) == b_iter && atomic_load(&g_inIter)) b_count++;
    usleep(900);
  }
  return NULL;
}

static int is_app_executable(void) {
  char exe[4096];
  uint32_t size = sizeof exe;
  if (_NSGetExecutablePath(exe, &size) != 0) return 0;
  const char *slash = strrchr(exe, '/');
  return slash && (strcmp(slash, "/Solara") == 0 || strcmp(slash, "/Solara") == 0) && strstr(exe, ".app/Contents/MacOS/") && !strstr(exe, "Helper");
}

__attribute__((constructor)) static void start(void) {
  const char *ms = getenv("AC_SAMPLE_MS");
  const char *scenario = getenv("AC_SAMPLE_SCENARIO");
  if (!ms && !scenario) return;
  if (!is_app_executable()) return;
  g_main = mach_thread_self();
  g_t0 = mach_absolute_time();
  pthread_t t;
  if (scenario) {
    CFRunLoopObserverRef o = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true, 0x7FFFFFF1, loop_activity, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
    pthread_create(&t, NULL, scenario_sampler, NULL);
    pthread_detach(t);
  }
  if (ms) {
    g_ms = atoi(ms);
    pthread_create(&t, NULL, sampler, NULL);
    pthread_detach(t);
  }
}
