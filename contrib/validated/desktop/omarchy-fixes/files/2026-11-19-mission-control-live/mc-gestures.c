// mc-gestures: print three- and four-finger touchpad gestures, one line each,
// for the Mission Control overlay to follow the fingers.
//
// It opens touchpads only (udev ID_INPUT_TOUCHPAD), never keyboards, through
// its own libinput context, read-only and without grabbing: Hyprland keeps
// getting every event. The user must be in the "input" group.
//
//   H <fingers>            fingers rested on the pad (hold began)
//   h <cancelled>          hold ended
//   B <fingers>            swipe began
//   U <dx> <dy> <msec>     swipe moved (unaccelerated units, +x right, +y down; time to the microsecond)
//   E <cancelled>          swipe ended
//
// libinput reports a swipe only after the fingers have travelled a few
// millimetres (it must tell a swipe from a pinch first), so an overview that
// waits for it trails the fingers. The pad's raw contacts are therefore read
// as well, from a second read-only descriptor on the same device:
//
//   T <count>              the number of fingers on the pad changed
//   RB                     three fingers started moving together
//   R <dx> <dy> <msec>     their centre moved (same units and signs as U)
//   RE                     one of them lifted, or another landed
//
// Build: cc -O2 -o mc-gestures mc-gestures.c $(pkg-config --cflags --libs libinput libudev) -lm
#include <errno.h>
#include <fcntl.h>
#include <libinput.h>
#include <libudev.h>
#include <linux/input.h>
#include <math.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <time.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define MAX_PADS 16
#define MAX_SLOTS 32

// Millimetres to libinput's unaccelerated touchpad units: 1000 dpi, times the
// 0.9 baseline and the 0.2968 slowdown of its touchpad filter.
#define UNITS_PER_MM 10.517

struct slot { int id, x, y, bx, by; };
struct pad {
  char node[128];
  struct libinput_device *dev;
  int fd;                       // raw contacts, -1 when unavailable
  double resx, resy;            // device units per millimetre
  int nslots, cur, idchanged;
  struct slot s[MAX_SLOTS];
  int count, armed, latched;
  double lastx, lasty;          // centre of the three fingers at the last line, mm from the baseline
};
static struct pad pads[MAX_PADS];

// For comparing the two sources in the log: libinput's travel against the
// raw centre's travel over the same swipe.
static double cal_li_x, cal_li_y, cal_raw_x0, cal_raw_y0, cal_raw_x, cal_raw_y;
static int cal_on;

static void emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void emit(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vprintf(fmt, ap);
  va_end(ap);
  if (n < 0 || fflush(stdout) != 0) exit(0); // the reader went away
}

static void raw_open(struct pad *p) {
  p->fd = open(p->node, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (p->fd < 0) return;
  struct input_absinfo ax, ay, as;
  if (ioctl(p->fd, EVIOCGABS(ABS_MT_POSITION_X), &ax) < 0 || ioctl(p->fd, EVIOCGABS(ABS_MT_POSITION_Y), &ay) < 0 ||
      ioctl(p->fd, EVIOCGABS(ABS_MT_SLOT), &as) < 0 || ax.resolution <= 0 || ay.resolution <= 0) {
    close(p->fd);
    p->fd = -1;
    return;
  }
  int clk = CLOCK_MONOTONIC;
  ioctl(p->fd, EVIOCSCLOCKID, &clk);
  p->resx = ax.resolution;
  p->resy = ay.resolution;
  p->nslots = as.maximum + 1 > MAX_SLOTS ? MAX_SLOTS : as.maximum + 1;
  p->cur = as.value >= 0 && as.value < p->nslots ? as.value : 0;
  for (int i = 0; i < MAX_SLOTS; i++) p->s[i].id = -1;
  p->count = p->armed = p->latched = p->idchanged = 0;
  fprintf(stderr, "mc-gestures: raw contacts on %s, %d slots, %.0f x %.0f units/mm\n", p->node, p->nslots, p->resx, p->resy);
}

// Events were dropped: forget every contact rather than act on a stale picture.
static void raw_reset(struct pad *p) {
  if (p->latched) emit("RE\n");
  for (int i = 0; i < MAX_SLOTS; i++) p->s[i].id = -1;
  p->armed = p->latched = p->idchanged = 0;
  if (p->count != 0) emit("T 0\n");
  p->count = 0;
}

static void raw_frame(struct pad *p, double ms) {
  int n = 0, idx[3];
  for (int i = 0; i < p->nslots; i++)
    if (p->s[i].id >= 0) { if (n < 3) idx[n] = i; n++; }

  if (n != p->count || p->idchanged) {
    if (p->latched) emit("RE\n");
    p->latched = 0;
    p->idchanged = 0;
    p->armed = n == 3;
    if (p->armed)
      for (int k = 0; k < 3; k++) { p->s[idx[k]].bx = p->s[idx[k]].x; p->s[idx[k]].by = p->s[idx[k]].y; }
    if (n != p->count) emit("T %d\n", n);
    p->count = n;
    return;
  }
  if (n != 3 || !p->armed) return;

  double dx[3], dy[3], cx = 0, cy = 0;
  for (int k = 0; k < 3; k++) {
    dx[k] = (p->s[idx[k]].x - p->s[idx[k]].bx) / p->resx;
    dy[k] = (p->s[idx[k]].y - p->s[idx[k]].by) / p->resy;
    cx += dx[k] / 3;
    cy += dy[k] / 3;
  }
  cal_raw_x = cx;
  cal_raw_y = cy;

  if (!p->latched) {
    // A swipe: all three fingers have moved the same way. A resting palm, a
    // pinch or a stray third finger under a two-finger scroll do not.
    int vertical = fabs(cy) >= fabs(cx);
    double c = vertical ? cy : cx;
    if (fabs(c) < 0.6) return;
    for (int k = 0; k < 3; k++) {
      double d = vertical ? dy[k] : dx[k];
      if (d * (c > 0 ? 1 : -1) < 0.4) {
        // Moved a long way without agreeing: not a swipe, stop looking.
        if (fabs(c) > 4.0) p->armed = 0;
        return;
      }
    }
    p->latched = 1;
    p->lastx = p->lasty = 0;
    emit("RB\n");
  }
  if (cx == p->lastx && cy == p->lasty) return;
  emit("R %.3f %.3f %.3f\n", (cx - p->lastx) * UNITS_PER_MM, (cy - p->lasty) * UNITS_PER_MM, ms);
  p->lastx = cx;
  p->lasty = cy;
}

static void raw_read(struct pad *p) {
  struct input_event ev[64];
  for (;;) {
    ssize_t n = read(p->fd, ev, sizeof ev);
    if (n < (ssize_t)sizeof ev[0]) {
      if (n < 0 && errno == EINTR) continue;
      if (n < 0 && errno != EAGAIN) { close(p->fd); p->fd = -1; }
      return;
    }
    for (size_t i = 0; i < n / sizeof ev[0]; i++) {
      const struct input_event *e = &ev[i];
      if (e->type == EV_ABS) {
        if (e->code == ABS_MT_SLOT) p->cur = e->value >= 0 && e->value < p->nslots ? e->value : p->nslots - 1;
        else if (e->code == ABS_MT_TRACKING_ID) { p->s[p->cur].id = e->value; p->idchanged = 1; }
        else if (e->code == ABS_MT_POSITION_X) p->s[p->cur].x = e->value;
        else if (e->code == ABS_MT_POSITION_Y) p->s[p->cur].y = e->value;
      } else if (e->type == EV_SYN) {
        if (e->code == SYN_DROPPED) raw_reset(p);
        else if (e->code == SYN_REPORT)
          raw_frame(p, e->input_event_sec * 1000.0 + e->input_event_usec / 1000.0);
      }
    }
  }
}

static int open_restricted(const char *path, int flags, void *data) {
  (void)data;
  int fd = open(path, flags | O_CLOEXEC);
  return fd < 0 ? -errno : fd;
}
static void close_restricted(int fd, void *data) { (void)data; close(fd); }
static const struct libinput_interface iface = { open_restricted, close_restricted };

static void add_pad(struct libinput *li, struct udev_device *d) {
  const char *node = udev_device_get_devnode(d);
  const char *tp = udev_device_get_property_value(d, "ID_INPUT_TOUCHPAD");
  if (!node || !tp || strcmp(tp, "1") != 0 || strncmp(node, "/dev/input/event", 16) != 0) return;
  int slot = -1;
  for (int i = 0; i < MAX_PADS; i++) {
    if (pads[i].dev && strcmp(pads[i].node, node) == 0) return;
    if (!pads[i].dev && slot < 0) slot = i;
  }
  if (slot < 0) return;
  struct libinput_device *dev = libinput_path_add_device(li, node);
  if (!dev) { fprintf(stderr, "mc-gestures: cannot open %s\n", node); return; }
  libinput_device_ref(dev);
  pads[slot].dev = dev;
  snprintf(pads[slot].node, sizeof pads[slot].node, "%s", node);
  fprintf(stderr, "mc-gestures: touchpad %s (%s)\n", libinput_device_get_name(dev), node);
  raw_open(&pads[slot]);
}

static void remove_pad(struct udev_device *d) {
  const char *node = udev_device_get_devnode(d);
  if (!node) return;
  for (int i = 0; i < MAX_PADS; i++) {
    if (pads[i].dev && strcmp(pads[i].node, node) == 0) {
      libinput_path_remove_device(pads[i].dev);
      libinput_device_unref(pads[i].dev);
      pads[i].dev = NULL;
      if (pads[i].fd >= 0) { if (pads[i].latched) emit("RE\n"); close(pads[i].fd); pads[i].fd = -1; }
      fprintf(stderr, "mc-gestures: removed %s\n", node);
    }
  }
}

static void handle(struct libinput_event *ev) {
  enum libinput_event_type type = libinput_event_get_type(ev);
  if (type < LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN || type > LIBINPUT_EVENT_GESTURE_HOLD_END) return;
  struct libinput_event_gesture *g = libinput_event_get_gesture_event(ev);
  int fingers = libinput_event_gesture_get_finger_count(g);
  if (fingers < 3) return;
  switch (type) {
  case LIBINPUT_EVENT_GESTURE_HOLD_BEGIN: emit("H %d\n", fingers); break;
  case LIBINPUT_EVENT_GESTURE_HOLD_END: emit("h %d\n", libinput_event_gesture_get_cancelled(g)); break;
  case LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN:
    cal_li_x = cal_li_y = 0;
    cal_raw_x0 = cal_raw_x;
    cal_raw_y0 = cal_raw_y;
    cal_on = 1;
    emit("B %d\n", fingers);
    break;
  case LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE:
    cal_li_x += libinput_event_gesture_get_dx_unaccelerated(g);
    cal_li_y += libinput_event_gesture_get_dy_unaccelerated(g);
    emit("U %.3f %.3f %.3f\n", libinput_event_gesture_get_dx_unaccelerated(g),
         libinput_event_gesture_get_dy_unaccelerated(g), libinput_event_gesture_get_time_usec(g) / 1000.0);
    break;
  case LIBINPUT_EVENT_GESTURE_SWIPE_END: {
    double li = hypot(cal_li_x, cal_li_y), raw = hypot(cal_raw_x - cal_raw_x0, cal_raw_y - cal_raw_y0);
    if (cal_on && fingers == 3 && raw > 5)
      fprintf(stderr, "mc-gestures: swipe libinput %.0f units, raw %.1f mm, %.2f units/mm, raw seen first by %.1f mm\n",
              li, raw, li / raw, hypot(cal_raw_x0, cal_raw_y0));
    cal_on = 0;
    emit("E %d\n", libinput_event_gesture_get_cancelled(g));
    break;
  }
  default: break;
  }
}

int main(void) {
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  signal(SIGPIPE, SIG_DFL);
  setvbuf(stdout, NULL, _IOLBF, 0);

  struct udev *udev = udev_new();
  struct libinput *li = libinput_path_create_context(&iface, NULL);
  if (!udev || !li) { fprintf(stderr, "mc-gestures: cannot start libinput\n"); return 1; }

  struct udev_monitor *mon = udev_monitor_new_from_netlink(udev, "udev");
  udev_monitor_filter_add_match_subsystem_devtype(mon, "input", NULL);
  udev_monitor_enable_receiving(mon);

  struct udev_enumerate *en = udev_enumerate_new(udev);
  udev_enumerate_add_match_subsystem(en, "input");
  udev_enumerate_add_match_property(en, "ID_INPUT_TOUCHPAD", "1");
  udev_enumerate_scan_devices(en);
  struct udev_list_entry *e;
  udev_list_entry_foreach(e, udev_enumerate_get_list_entry(en)) {
    struct udev_device *d = udev_device_new_from_syspath(udev, udev_list_entry_get_name(e));
    if (d) { add_pad(li, d); udev_device_unref(d); }
  }
  udev_enumerate_unref(en);

  for (int i = 0; i < MAX_PADS; i++) if (!pads[i].dev) pads[i].fd = -1;
  for (;;) {
    struct pollfd fds[2 + MAX_PADS] = {
      { .fd = libinput_get_fd(li), .events = POLLIN },
      { .fd = udev_monitor_get_fd(mon), .events = POLLIN },
    };
    int nfds = 2, who[MAX_PADS];
    for (int i = 0; i < MAX_PADS; i++)
      if (pads[i].dev && pads[i].fd >= 0) { who[nfds - 2] = i; fds[nfds++] = (struct pollfd){ .fd = pads[i].fd, .events = POLLIN }; }
    if (poll(fds, nfds, -1) < 0) { if (errno == EINTR) continue; return 1; }
    // Raw contacts first: they are the earlier word on the same movement.
    for (int k = 2; k < nfds; k++)
      if (fds[k].revents & (POLLIN | POLLERR | POLLHUP)) raw_read(&pads[who[k - 2]]);
    if (fds[1].revents & POLLIN) {
      struct udev_device *d = udev_monitor_receive_device(mon);
      if (d) {
        const char *action = udev_device_get_action(d);
        if (action && strcmp(action, "add") == 0) add_pad(li, d);
        else if (action && strcmp(action, "remove") == 0) remove_pad(d);
        udev_device_unref(d);
      }
    }
    libinput_dispatch(li);
    struct libinput_event *ev;
    while ((ev = libinput_get_event(li))) { handle(ev); libinput_event_destroy(ev); }
  }
}
