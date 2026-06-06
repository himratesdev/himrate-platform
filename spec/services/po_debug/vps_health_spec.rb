# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::VpsHealth do
  describe ".call" do
    let(:tmpdir) { Dir.mktmpdir("po_debug_vps_") }
    let(:host_proc) { File.join(tmpdir, "proc") }
    let(:host_sys)  { File.join(tmpdir, "sys") }

    before do
      stub_const("PoDebug::VpsHealth::HOST_PROC", host_proc)
      stub_const("PoDebug::VpsHealth::HOST_SYS",  host_sys)
      FileUtils.mkdir_p(host_proc)
      FileUtils.mkdir_p(File.join(host_sys, "block/sda"))
    end

    after { FileUtils.rm_rf(tmpdir) }

    context "host /proc + /sys readable" do
      before do
        File.write("#{host_proc}/loadavg",  "21.55 21.97 22.15 4/1234 5678")
        File.write("#{host_proc}/uptime",   "97200.5 350000.0")
        File.write("#{host_proc}/cpuinfo",  "processor\t: 0\nprocessor\t: 1\nprocessor\t: 2\n")
        File.write("#{host_proc}/meminfo", <<~MEMINFO)
          MemTotal:       8133456 kB
          MemFree:         300000 kB
          MemAvailable:   3000000 kB
          SwapTotal:      2097148 kB
          SwapFree:       1200000 kB
        MEMINFO
        # 11 fields per Linux kernel disk stat docs: reads merged-reads sectors
        # read_ms writes merged_writes sectors write_ms io_in_progress io_ticks
        # time_in_queue
        File.write("#{host_sys}/block/sda/stat", "100 0 0 0 50 0 0 0 1 200 0")
      end

      it "returns full payload with load/memory/swap/disk/uptime" do
        result = described_class.call

        expect(result[:load][:one_min]).to eq(21.55)
        expect(result[:load][:five_min]).to eq(21.97)
        expect(result[:load][:cpu_count]).to eq(3)
        expect(result[:memory][:total_mib]).to eq(7943)
        expect(result[:memory][:available_mib]).to eq(2930)
        expect(result[:swap][:used_pct]).to be_within(0.5).of(42.8)
        expect(result[:uptime_hours]).to eq(27.0)
        expect(result[:source]).to eq("host_proc")
      end

      it "computes disk iops + util across two 100ms snapshots" do
        # First read happens immediately; thread sleeps 100ms then re-reads.
        # Both snapshots use the same stat file → delta = 0 → util_pct = 0.0.
        # Validates the shape of the result; numerical disk delta covered by
        # higher-level integration when /host/sys/block/sda/stat changes
        # between calls (live VPS scenario).
        result = described_class.call
        expect(result[:disk]).to include(:util_pct, :queue_depth, :read_iops, :write_iops)
        expect(result[:disk][:queue_depth]).to eq(1)
      end
    end

    context "host /proc missing (local dev without mount)" do
      it "returns per-section errors, does not raise" do
        result = described_class.call
        expect(result[:load]).to include(:error)
        expect(result[:memory]).to include(:error)
        expect(result[:swap]).to include(:error)
        expect(result[:disk]).to include(:error)
        # Source still reported so Aggregator can surface the degraded state.
        expect(result[:source]).to eq("host_proc")
      end
    end
  end
end
