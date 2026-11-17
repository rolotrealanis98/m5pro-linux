# Source from leak-probe.sh after HPID, HLOG/SIG, XRD and APPLE are set; call sample_extra once per sample
# next to sample(). One line per call. No kprobes or function tracer in this kernel config, so everything
# comes from procfs/debugfs and the Hyprland log.
#
#   rcfg  "Reconfigured a swapchain" lines so far (each = 3 new 31 MB dumb buffers on the apple card)
#   ar24  of those, to AR24 (direct-scanout attempts at the client's format)
#   hfd   Hyprland's open fds; hdmabuf = those that are dma-bufs (one per live GBM buffer in aquamarine)
#   dbuf  dma-buf objects / MB in the system; d31 = dma-bufs of exactly 30883840 bytes (3456x2234 XR24/AR24)
#   afb   framebuffers alive on the apple card (RMFB'd but still referenced ones stay listed)
#   hidden  MB of RAM in no /proc/meminfo bucket (dma_alloc_wc pages of apple-drm dumb buffers land here)
sample_extra() {
  local log="$XRD/hypr/$SIG/hyprland.log" bi=/sys/kernel/debug/dma_buf/bufinfo
  local rcfg ar24 hfd hdmabuf dbuf d31 afb hidden
  rcfg=$(tr -d '\000' < "$log" 2>/dev/null | grep -ac 'Reconfigured a swapchain')
  ar24=$(tr -d '\000' < "$log" 2>/dev/null | grep -ac 'Reconfigured a swapchain.*AR24')
  hfd=$(ls /proc/"$HPID"/fd 2>/dev/null | wc -l)
  hdmabuf=$(ls -l /proc/"$HPID"/fd 2>/dev/null | grep -c dmabuf)
  # bufinfo: header "Dma-buf Objects:", one "%08zu size ..." line per object, "Total N objects, B bytes".
  dbuf=$(awk '/^Total [0-9]+ objects/{printf "%d/%dMB", $2, $4/1048576}' "$bi" 2>/dev/null)
  d31=$(awk '$1 ~ /^[0-9]+$/ && $1+0 == 30883840' "$bi" 2>/dev/null | wc -l)
  afb=$(grep -c '^framebuffer\[' /sys/kernel/debug/dri/"$APPLE"/framebuffer 2>/dev/null)
  hidden=$(awk '{v[$1]=$2} END{h=v["MemTotal:"]-v["MemFree:"]-v["Active:"]-v["Inactive:"]-v["Unevictable:"]-v["Slab:"]-v["KernelStack:"]-v["PageTables:"]-v["SecPageTables:"]-v["Percpu:"]-v["VmallocUsed:"]; printf "%d", h/1024}' /proc/meminfo)
  echo "    rcfg=$rcfg ar24=$ar24 hfd=$hfd hdmabuf=$hdmabuf dbuf=$dbuf d31=$d31 afb=$afb hidden=${hidden}MB"
}
