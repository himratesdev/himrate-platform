# frozen_string_literal: true

module SocialAnalytics
  module Telegram
    # DESCRIPTIVE observations about a Telegram channel's public numbers — never a verdict.
    #
    # The canon is deliberate: fraud verdicts live on Twitch, where we watch viewers and chat second
    # by second. For socials we only see a public preview, so the honest product is «вот что видно»
    # rather than «вот кто накрутил». Every line below therefore states an observation and, where we
    # can, its likely benign explanation (a giveaway, a repost) — the same neutral wording rule the
    # Twitch verdicts follow: no «боты», no «накрутка».
    #
    # Thresholds are set against a measured baseline of streamer channels (median view/sub ≈ 42%,
    # median view spread ≈ 0.29), not invented.
    class Observations
      VIEW_SUB_HIGH = 100      # more views than subscribers — content travelled beyond the channel
      VIEW_SUB_LOW = 12        # very few subscribers read the posts
      FLAT_VIEWS_CV = 0.08     # near-identical view counts across posts
      LOW_REACTION_ER = 0.5    # reactions per view, %
      SPIKE_FACTOR = 3.0       # a post this far above the channel's own median stands out

      Observation = Struct.new(:code, :text, :tone, :evidence, keyword_init: true)

      def self.call(profile, posts_context: nil)
        new(profile, posts_context).call
      end

      def initialize(profile, posts_context = nil)
        @profile = profile || {}
        @metrics = @profile[:metrics] || {}
        @posts = @profile[:posts] || []
        @context = posts_context || {}
      end

      def call
        [ reach_beyond_subscribers, thin_readership, flat_views, silent_audience, explained_spike ].compact
      end

      private

      def obs(code, text, tone, evidence)
        Observation.new(code: code, text: text, tone: tone, evidence: evidence)
      end

      # >100% is not automatically inflation: reposts and contests legitimately carry a post beyond
      # the subscriber base. Say what is seen, and name the explanation when the posts show one.
      def reach_beyond_subscribers
        ratio = @metrics[:view_sub_ratio].to_f
        return nil if ratio < VIEW_SUB_HIGH

        explanation = @context[:reposted] ? " — посты расходятся по другим каналам" : nil
        explanation ||= @context[:giveaway] ? " — в канале был розыгрыш" : ""
        obs("VIEW_ABOVE_SUBS",
            "Просмотров больше, чем подписчиков (#{ratio.round}%)#{explanation}",
            explanation.present? ? "info" : "warn",
            { view_sub_ratio: ratio.round(1) })
      end

      def thin_readership
        ratio = @metrics[:view_sub_ratio].to_f
        return nil if ratio.zero? || ratio >= VIEW_SUB_LOW

        obs("VIEW_BELOW_SUBS",
            "Посты читает малая часть подписчиков (#{ratio.round}%)",
            "warn", { view_sub_ratio: ratio.round(1) })
      end

      # Real audiences give ragged view counts; a near-flat line is what delivered views look like.
      def flat_views
        cv = @metrics[:view_cv].to_f
        return nil if cv.zero? || cv > FLAT_VIEWS_CV || @posts.size < 5

        obs("FLAT_VIEWS", "Просмотры у постов почти одинаковые (разброс #{(cv * 100).round}%)",
            "warn", { view_cv: cv.round(3), posts: @posts.size })
      end

      def silent_audience
        er = @metrics[:er_percent].to_f
        views = @metrics[:avg_views].to_i
        return nil if er.zero? || er >= LOW_REACTION_ER || views < 500

        obs("LOW_REACTIONS", "Реакций почти нет при заметных просмотрах (#{er}% от просмотров)",
            "warn", { er_percent: er, avg_views: views })
      end

      # A single outlier post explains a channel-level average far better than any suspicion does.
      def explained_spike
        values = @posts.map { |p| p[:views].to_i }.reject(&:zero?).sort
        return nil if values.size < 5

        median = values[values.size / 2]
        top = values.last
        return nil if median.zero? || top < median * SPIKE_FACTOR

        spike_post = @posts.max_by { |p| p[:views].to_i }
        reason = if spike_post && giveaway?(spike_post[:text]) then "похоже на розыгрыш"
        elsif @context[:reposted] then "пост разошёлся по другим каналам"
        else "разовый выброс"
        end
        obs("VIEW_SPIKE",
            "Один пост собрал в #{(top.to_f / median).round(1)} раза больше медианы — #{reason}",
            "info", { top_views: top, median_views: median })
      end

      GIVEAWAY_WORDS = /розыгрыш|конкурс|giveaway|приз|разыгрыва|дарим|подарок/i

      def giveaway?(text)
        text.present? && text.match?(GIVEAWAY_WORDS)
      end
    end
  end
end
