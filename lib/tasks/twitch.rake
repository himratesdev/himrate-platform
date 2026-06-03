# frozen_string_literal: true

# BUG-251.31 G-3: chatter sweep probe.
# Lets us measure on staging how much extra unique-viewer coverage we get from
# firing N parallel CommunityTab calls vs the single-call 100-entry cap, before
# wiring the parallel sweep into any worker. Real-data calibration per
# [[feedback-no-throwaway-go-to-final-architecture]] — we don't lock in the
# N=50 default until we see what randomness Twitch returns for OUR channels.

namespace :twitch do
  desc "G-3 probe: measure parallel CommunityTab sweep coverage on a live channel " \
       "(usage: rake 'twitch:probe_chatter_sweep[mizkif,20]')"
  task :probe_chatter_sweep, %i[channel_login concurrent_calls] => :environment do |_, args|
    channel_login = args[:channel_login].to_s.strip
    concurrent_calls = (args[:concurrent_calls] || 20).to_i

    if channel_login.blank?
      puts "usage: rake 'twitch:probe_chatter_sweep[channel_login,concurrent_calls]'"
      exit 1
    end

    client = Twitch::GqlClient.new

    puts "═══ G-3 chatter sweep probe ═══"
    puts "channel:           #{channel_login}"
    puts "concurrent calls:  #{concurrent_calls}"
    puts

    # Baseline: single call
    t0 = Time.current
    single = client.community_tab(channel_login: channel_login)
    single_ms = ((Time.current - t0) * 1000).round
    if single.nil?
      puts "❌ baseline single call failed (community_tab returned nil — channel offline / errored)"
      exit 2
    end

    single_viewers = (single[:viewers] || []).size
    puts "📊 baseline single CommunityTab:"
    puts "   elapsed_ms:        #{single_ms}"
    puts "   chatters.count:    #{single[:count]}"
    puts "   viewers[] sample:  #{single_viewers}"
    puts "   broadcasters:      #{(single[:broadcasters] || []).size}"
    puts "   moderators:        #{(single[:moderators] || []).size}"
    puts "   vips:              #{(single[:vips] || []).size}"
    puts "   staff:             #{(single[:staff] || []).size}"
    puts

    # Parallel sweep
    t1 = Time.current
    parallel = client.community_tab_parallel(channel_login: channel_login, concurrent_calls: concurrent_calls)
    parallel_ms = ((Time.current - t1) * 1000).round
    if parallel.nil?
      puts "❌ parallel sweep returned nil (all #{concurrent_calls} threads errored)"
      exit 3
    end

    puts "📊 parallel CommunityTab sweep:"
    puts "   elapsed_ms:        #{parallel_ms}"
    puts "   parallel_calls:    #{parallel[:parallel_calls]}"
    puts "   successful_calls:  #{parallel[:successful_calls]}"
    puts "   viewer_samples_sum:#{parallel[:viewer_samples_total]}"
    puts "   unique viewers:    #{parallel[:unique_viewer_logins]}"
    puts "   dedupe_ratio:      #{parallel[:dedupe_ratio]} (unique / sum_samples)"
    puts "   chatters.count:    #{parallel[:count]}"
    puts

    lift_pct =
      if single_viewers.positive?
        (((parallel[:unique_viewer_logins].to_f / single_viewers) - 1) * 100).round(1)
      else
        0.0
      end

    puts "🎯 coverage lift vs single: +#{lift_pct}% (#{parallel[:unique_viewer_logins] - single_viewers} additional unique viewers)"
    puts "📐 cap status: #{single_viewers >= 100 ? '⚠️ single call HIT the 100-viewer cap → parallel sweep IS valuable' : '✅ single call under cap, parallel marginal'}"
    puts
    puts "💡 next: run this on 5-10 currently-live big channels (CCV > 500, count > 100) to size " \
         "the production concurrent_calls value before wiring into a worker."
  end
end
