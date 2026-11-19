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
//   U <dx> <dy> <msec>     swipe moved (unaccelerated units, +x right, +y down)
//   E <cancelled>          swipe ended
//
// Build: cc -O2 -o mc-gestures mc-gestures.c $(pkg-config --cflags --libs libinput libudev)
#include <errno.h>
#include <fcntl.h>
#include <libinput.h>
#include <libudev.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define MAX_PADS 16

static struct { char node[128]; struct libinput_device *dev; } pads[MAX_PADS];

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
}

static void remove_pad(struct udev_device *d) {
  const char *node = udev_device_get_devnode(d);
  if (!node) return;
  for (int i = 0; i < MAX_PADS; i++) {
    if (pads[i].dev && strcmp(pads[i].node, node) == 0) {
      libinput_path_remove_device(pads[i].dev);
      libinput_device_unref(pads[i].dev);
      pads[i].dev = NULL;
      fprintf(stderr, "mc-gestures: removed %s\n", node);
    }
  }
}

static void emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void emit(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vprintf(fmt, ap);
  va_end(ap);
  if (n < 0 || fflush(stdout) != 0) exit(0); // the reader went away
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
  case LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN: emit("B %d\n", fingers); break;
  case LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE:
    emit("U %.3f %.3f %u\n", libinput_event_gesture_get_dx_unaccelerated(g),
         libinput_event_gesture_get_dy_unaccelerated(g), libinput_event_gesture_get_time(g));
    break;
  case LIBINPUT_EVENT_GESTURE_SWIPE_END: emit("E %d\n", libinput_event_gesture_get_cancelled(g)); break;
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

  struct pollfd fds[2] = {
    { .fd = libinput_get_fd(li), .events = POLLIN },
    { .fd = udev_monitor_get_fd(mon), .events = POLLIN },
  };
  for (;;) {
    if (poll(fds, 2, -1) < 0) { if (errno == EINTR) continue; return 1; }
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
