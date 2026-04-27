# frozen_string_literal: true

require "rails_helper"

RSpec.describe RevenueBaseline, type: :model do
  let(:base_attrs) do
    {
      period_start: 30.days.ago.to_date,
      period_end: 1.day.ago.to_date,
      daily_revenue_usd: 250.50,
      calculated_at: Time.current,
      accessory_revenue_weights: {}
    }
  end

  describe "validations" do
    it "is valid с base attrs" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[period_start period_end daily_revenue_usd calculated_at].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.merge(attr => nil))).not_to be_valid
      end
    end

    it "rejects negative daily_revenue_usd" do
      expect(described_class.new(base_attrs.merge(daily_revenue_usd: -1))).not_to be_valid
    end

    it "rejects period_end before period_start" do
      record = described_class.new(base_attrs.merge(
        period_start: Date.current, period_end: Date.current - 1
      ))
      expect(record).not_to be_valid
      expect(record.errors[:period_end]).to be_present
    end
  end

  describe "#weight_for" do
    it "returns custom weight when accessory_revenue_weights overrides" do
      record = described_class.new(base_attrs.merge(accessory_revenue_weights: { "redis" => 0.5 }))
      expect(record.weight_for("redis")).to eq(0.5)
    end

    it "falls back to DEFAULT_WEIGHTS when not overridden" do
      record = described_class.new(base_attrs)
      expect(record.weight_for("db")).to eq(1.0)
      expect(record.weight_for("redis")).to eq(0.8)
      expect(record.weight_for("grafana")).to eq(0.0)
    end

    it "returns 0.0 для unknown accessory" do
      record = described_class.new(base_attrs)
      expect(record.weight_for("unknown_thing")).to eq(0.0)
    end
  end

  describe "DEFAULT_WEIGHTS" do
    it "carries weights per ADR DEC-18 (db=1.0, redis=0.8, observability=0.0)" do
      expect(described_class::DEFAULT_WEIGHTS).to include(
        "db" => 1.0, "redis" => 0.8,
        "grafana" => 0.0, "prometheus" => 0.0, "loki" => 0.0,
        "alertmanager" => 0.0, "promtail" => 0.0, "prometheus-pushgateway" => 0.0
      )
    end
  end

  describe ".latest" do
    it "returns most recently calculated record" do
      old = described_class.create!(base_attrs.merge(calculated_at: 2.days.ago))
      new_one = described_class.create!(base_attrs.merge(calculated_at: 1.minute.ago))
      expect(described_class.latest).to eq(new_one)
      expect(old.id).not_to eq(new_one.id)
    end
  end
end
