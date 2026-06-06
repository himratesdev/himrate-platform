# frozen_string_literal: true

module PoDebug
  # Block 5 — VPS host metrics via /host/proc + /host/sys read-only mounts.
  #
  # Replaces the Prometheus accessory dependency (accessory was disabled in
  # PR-B2 #285 to free ~480 MiB RAM + 6 disk-writers competing with Sidekiq +
  # ClickHouse + PG). Reading /proc directly is faster (single fs op), removes
  # one runtime dependency, and aligns with EPIC SCALE ARCHITECTURE §2 (obs
  # MUST NEVER live on compute box). Multi-host topology: each replica reads
  # its own /proc via the same mount — no shared scrape target.
  #
  # All reads wrapped in a per-section rescue. Missing /host/proc (e.g.
  # local dev without the mount) → returns per-section `{ error: ... }`
  # payloads; siblings continue to render.
  class VpsHealth
    HOST_PROC = "/host/proc"
    HOST_SYS  = "/host/sys"

    def self.call
      new.call
    end

    def call
      {
        load: load_metrics,
        memory: memory_metrics,
        swap: swap_metrics,
        disk: disk_metrics,
        uptime_hours: uptime_hours,
        source: "host_proc",
        host_proc_path: HOST_PROC
      }
    end

    private

    # /host/proc/loadavg format: "21.55 21.97 22.15 4/1234 5678".
    # CPU count from /host/proc/cpuinfo (count of "processor" lines).
    def load_metrics
      raw = read("#{HOST_PROC}/loadavg")
      fields = raw.split
      {
        one_min: fields[0]&.to_f,
        five_min: fields[1]&.to_f,
        fifteen_min: fields[2]&.to_f,
        cpu_count: cpu_count
      }
    rescue StandardError => e
      { error: "loadavg read failed: #{e.class}: #{e.message}" }
    end

    def cpu_count
      File.foreach("#{HOST_PROC}/cpuinfo").count { |line| line.start_with?("processor") }
    rescue StandardError
      nil
    end

    # /host/proc/meminfo format: "MemTotal:       8133456 kB" — kB units.
    def memory_metrics
      meminfo = parse_meminfo
      total = kb_to_mib(meminfo["MemTotal"])
      available = kb_to_mib(meminfo["MemAvailable"])

      used = total && available ? (total - available).round(0) : nil
      used_pct = total && available && total.positive? ?
                   (((total - available) / total.to_f) * 100).round(1) : nil

      { total_mib: total, available_mib: available, used_mib: used, used_pct: used_pct }
    rescue StandardError => e
      { error: "memory read failed: #{e.class}: #{e.message}" }
    end

    def swap_metrics
      meminfo = parse_meminfo
      total = kb_to_mib(meminfo["SwapTotal"])
      free = kb_to_mib(meminfo["SwapFree"])

      used = total && free ? (total - free).round(0) : nil
      used_pct = total && free && total.positive? ?
                   (((total - free) / total.to_f) * 100).round(1) : nil

      { total_mib: total, free_mib: free, used_mib: used, used_pct: used_pct }
    rescue StandardError => e
      { error: "swap read failed: #{e.class}: #{e.message}" }
    end

    # /host/sys/block/sda/stat — 11 fields per Linux kernel docs:
    #   reads, reads_merged, sectors_read, ms_reading,
    #   writes, writes_merged, sectors_written, ms_writing,
    #   io_in_progress, io_ticks_ms, time_in_queue_ms
    # %util + IOPS via two ~100 ms snapshots — wall-clock measured because
    # sleep(0.1) is a floor not a fixed window: on the loaded VPS that
    # motivates this dashboard (load 20+, swap-thrash) the wake can drift
    # to 150-300 ms, which would over-report %util by the same factor if we
    # hardcoded the denominator. Process.clock_gettime keeps math honest.
    def disk_metrics
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      first = read_disk_stat
      sleep 0.1
      second = read_disk_stat
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      return { error: "disk stat unavailable" } unless first && second

      elapsed_ms = (t1 - t0).to_f
      return { error: "disk stat elapsed window collapsed" } if elapsed_ms <= 0

      delta_ms = second[:io_ticks_ms] - first[:io_ticks_ms]
      util_pct = (delta_ms / elapsed_ms * 100).round(1)
      util_pct = 100.0 if util_pct > 100

      elapsed_sec = elapsed_ms / 1000.0
      {
        util_pct: util_pct,
        queue_depth: second[:io_in_progress],
        read_iops: ((second[:reads] - first[:reads]) / elapsed_sec).round(0),
        write_iops: ((second[:writes] - first[:writes]) / elapsed_sec).round(0)
      }
    rescue StandardError => e
      { error: "disk read failed: #{e.class}: #{e.message}" }
    end

    def read_disk_stat
      raw = read("#{HOST_SYS}/block/sda/stat")
      f = raw.split.map(&:to_i)
      { reads: f[0], writes: f[4], io_in_progress: f[8], io_ticks_ms: f[9] }
    rescue StandardError
      nil
    end

    # /host/proc/uptime: "uptime_seconds idle_seconds".
    def uptime_hours
      raw = read("#{HOST_PROC}/uptime")
      seconds = raw.split.first.to_f
      (seconds / 3600.0).round(1)
    rescue StandardError
      nil
    end

    def parse_meminfo
      @meminfo ||= File.foreach("#{HOST_PROC}/meminfo").each_with_object({}) do |line, h|
        key, value = line.split(":", 2)
        h[key] = value.to_s.strip.split.first.to_i
      end
    end

    def read(path)
      File.read(path).strip
    end

    def kb_to_mib(kb)
      return nil unless kb && kb.positive?

      (kb / 1024.0).round(0)
    end
  end
end
