# frozen_string_literal: true

require "rails_helper"
require "rake"

# P2 2026-09-02: the GATE-0 calibration scripts moved from workflow-YAML heredocs into rake
# (ti_v2:shadow_mine / ti_v2:rho_reseed) so they are runnable without GitHub and testable.
# These specs pin the safety contract, not the calibration math (that ran live on HOSTKEY).
RSpec.describe "ti_v2 calibration rake tasks" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }
  before { Rake::Task.tasks.each(&:reenable) }

  describe "ti_v2:shadow_mine" do
    it "is defined" do
      expect(Rake::Task.task_defined?("ti_v2:shadow_mine")).to be true
    end

    it "runs on an empty shadow-lines file and reports zero usable lines" do
      path = Rails.root.join("tmp", "shadow_lines_spec.txt").to_s
      File.write(path, "")
      ENV["SHADOW_LINES"] = path
      ENV["MINE_CONV"] = "windowed"
      expect { Rake::Task["ti_v2:shadow_mine"].invoke }
        .to output(/shadow lines: 0 total, 0 usable, 0 distinct streams/).to_stdout
    ensure
      ENV.delete("SHADOW_LINES")
      ENV.delete("MINE_CONV")
      FileUtils.rm_f(path)
    end
  end

  describe "ti_v2:rho_reseed" do
    it "is defined" do
      expect(Rake::Task.task_defined?("ti_v2:rho_reseed")).to be true
    end

    it "aborts when cells_json is empty (never touches the table)" do
      ENV["RESEED_MODE"] = "dryrun"
      ENV["CELLS_JSON"] = "[]"
      expect { Rake::Task["ti_v2:rho_reseed"].invoke }
        .to raise_error(SystemExit).and output(/no cells provided/).to_stderr
      expect(CalibrationCellBaseline.count).to eq(0)
    ensure
      ENV.delete("RESEED_MODE")
      ENV.delete("CELLS_JSON")
    end

    it "dryrun upserts inside a rolled-back transaction (cell table unchanged)" do
      ENV["RESEED_MODE"] = "dryrun"
      ENV["HONEST_SAMPLE"] = "20"
      ENV["CELLS_JSON"] = [ { cat: "gaming", vb: "1k-5k", cm: "open", lang: "RU",
                              star: 0.09, lo: 0.05, hi: 0.15, n: 11 } ].to_json
      before_count = CalibrationCellBaseline.count
      expect { Rake::Task["ti_v2:rho_reseed"].invoke }
        .to output(/DRYRUN SAFE|DRYRUN UNSAFE/).to_stdout
      expect(CalibrationCellBaseline.count).to eq(before_count)
      expect(CalibrationCellBaseline.find_by(category: "gaming", v_bucket: "1k-5k")).to be_nil
    ensure
      ENV.delete("RESEED_MODE")
      ENV.delete("HONEST_SAMPLE")
      ENV.delete("CELLS_JSON")
    end
  end
end
