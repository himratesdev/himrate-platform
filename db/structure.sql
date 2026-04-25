SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: anomalies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomalies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    anomaly_type character varying(30) NOT NULL,
    cause character varying(30),
    ccv_impact integer,
    confidence numeric(5,4),
    details jsonb DEFAULT '{}'::jsonb,
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: anomaly_attributions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_attributions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    anomaly_id uuid NOT NULL,
    source character varying(50) NOT NULL,
    confidence numeric(5,4) NOT NULL,
    raw_source_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    attributed_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    key_hash character varying(255) NOT NULL,
    last_used_at timestamp(6) without time zone,
    name character varying(255) NOT NULL,
    rate_limit integer DEFAULT 20 NOT NULL,
    scopes jsonb DEFAULT '[]'::jsonb,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: attribution_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attribution_sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source character varying(50) NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    priority integer DEFAULT 999 NOT NULL,
    adapter_class_name character varying(100) NOT NULL,
    display_label_en character varying(100) NOT NULL,
    display_label_ru character varying(100) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: auth_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    error_type character varying(50),
    extension_version character varying(20),
    ip_address inet,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    provider character varying(20) NOT NULL,
    result character varying(20) NOT NULL,
    user_agent text,
    user_id uuid
);


--
-- Name: auth_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_providers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    access_token text,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone,
    is_broadcaster boolean DEFAULT false NOT NULL,
    provider character varying(20) NOT NULL,
    provider_id character varying(255) NOT NULL,
    refresh_token text,
    scopes jsonb DEFAULT '[]'::jsonb,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: billing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    amount numeric(10,2),
    created_at timestamp(6) without time zone NOT NULL,
    currency character varying(3),
    event_type character varying(50) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    provider character varying(20) NOT NULL,
    provider_event_id character varying(255) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: ccv_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ccv_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ccv_count integer NOT NULL,
    confidence numeric(5,4),
    real_viewers_estimate integer,
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: channel_protection_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_protection_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    channel_protection_score numeric(5,2),
    email_verification_required boolean DEFAULT false NOT NULL,
    emote_only_enabled boolean DEFAULT false NOT NULL,
    followers_only_duration_min integer,
    last_checked_at timestamp(6) without time zone,
    minimum_account_age_minutes integer,
    phone_verification_required boolean DEFAULT false NOT NULL,
    restrict_first_time_chatters boolean DEFAULT false NOT NULL,
    slow_mode_seconds integer,
    subs_only_enabled boolean DEFAULT false NOT NULL
);


--
-- Name: channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    broadcaster_type character varying(20),
    created_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone,
    description text,
    display_name character varying(255),
    followers_total integer DEFAULT 0,
    is_monitored boolean DEFAULT false NOT NULL,
    login character varying(255) NOT NULL,
    profile_image_url text,
    twitch_account_created_at timestamp(6) without time zone,
    twitch_id character varying(50) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    timezone character varying(50) DEFAULT 'UTC'::character varying NOT NULL
);


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    badge_info character varying(255),
    bits_used integer DEFAULT 0,
    channel_login character varying(255) NOT NULL,
    color character varying(7),
    display_name character varying(255),
    emotes text,
    entropy numeric(8,4),
    is_first_msg boolean DEFAULT false NOT NULL,
    message_text text,
    msg_type character varying(20) DEFAULT 'privmsg'::character varying NOT NULL,
    raw_tags jsonb DEFAULT '{}'::jsonb NOT NULL,
    returning_chatter boolean DEFAULT false NOT NULL,
    stream_id uuid,
    subscriber_status character varying(10),
    "timestamp" timestamp(6) without time zone NOT NULL,
    twitch_msg_id character varying(255),
    user_type character varying(10),
    username character varying(255) NOT NULL,
    vip boolean DEFAULT false NOT NULL
);


--
-- Name: chatters_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chatters_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    auth_ratio numeric(5,4),
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL,
    total_messages_count integer NOT NULL,
    unique_chatters_count integer NOT NULL
);


--
-- Name: cross_channel_presences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cross_channel_presences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    first_seen_at timestamp(6) without time zone NOT NULL,
    last_seen_at timestamp(6) without time zone NOT NULL,
    message_count integer DEFAULT 0 NOT NULL,
    stream_id uuid,
    username character varying(255) NOT NULL
);


--
-- Name: dismissed_recommendations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dismissed_recommendations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    dismissed_at timestamp(6) without time zone NOT NULL,
    rule_id character varying(10) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: erv_estimates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.erv_estimates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    confidence numeric(5,4),
    erv_count integer NOT NULL,
    erv_percent numeric(5,2) NOT NULL,
    label character varying(30),
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: flipper_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.flipper_features (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    key character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: flipper_features_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.flipper_features_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: flipper_features_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.flipper_features_id_seq OWNED BY public.flipper_features.id;


--
-- Name: flipper_gates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.flipper_gates (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    feature_key character varying NOT NULL,
    key character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    value text
);


--
-- Name: flipper_gates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.flipper_gates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: flipper_gates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.flipper_gates_id_seq OWNED BY public.flipper_gates.id;


--
-- Name: follower_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follower_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    followers_count integer NOT NULL,
    new_followers_24h integer,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: health_score_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_score_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    display_name character varying(100) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    key character varying(100) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: health_score_category_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_score_category_aliases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    game_name_alias character varying(200) NOT NULL,
    health_score_category_id uuid NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: health_score_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_score_tiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bg_hex character varying(7) NOT NULL,
    color_name character varying(20) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    display_order integer NOT NULL,
    i18n_key character varying(50) NOT NULL,
    key character varying(20) NOT NULL,
    max_score integer NOT NULL,
    min_score integer NOT NULL,
    text_hex character varying(7) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: health_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    calculated_at timestamp(6) without time zone NOT NULL,
    category character varying(100),
    channel_id uuid NOT NULL,
    confidence_level character varying(20),
    consistency_component numeric(5,2),
    engagement_component numeric(5,2),
    growth_component numeric(5,2),
    health_score numeric(5,2) NOT NULL,
    hs_classification character varying(20),
    stability_component numeric(5,2),
    stream_id uuid,
    ti_component numeric(5,2),
    CONSTRAINT hs_classification_5tier CHECK (((hs_classification)::text = ANY (ARRAY[('excellent'::character varying)::text, ('good'::character varying)::text, ('average'::character varying)::text, ('below_average'::character varying)::text, ('poor'::character varying)::text])))
);


--
-- Name: hs_tier_change_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hs_tier_change_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    event_type character varying(30) DEFAULT 'tier_change'::character varying NOT NULL,
    from_tier character varying(30),
    hs_after numeric(5,2) NOT NULL,
    hs_before numeric(5,2),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    stream_id uuid,
    to_tier character varying(30) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: known_bot_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.known_bot_lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    added_at timestamp(6) without time zone NOT NULL,
    bot_category character varying(20) DEFAULT 'unknown'::character varying NOT NULL,
    confidence numeric(5,4) NOT NULL,
    last_seen_at timestamp(6) without time zone,
    source character varying(30) NOT NULL,
    username character varying(255) NOT NULL,
    verified boolean DEFAULT false NOT NULL
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid,
    created_at timestamp(6) without time zone NOT NULL,
    priority character varying(10),
    read_at timestamp(6) without time zone,
    sent_at timestamp(6) without time zone,
    stream_id uuid,
    type character varying(50) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: pdf_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pdf_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone,
    file_path text,
    is_white_label boolean DEFAULT false NOT NULL,
    price_charged numeric(10,2),
    report_type character varying(20) NOT NULL,
    share_token character varying(64),
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: per_user_bot_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.per_user_bot_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bot_score numeric(5,4) NOT NULL,
    classification character varying(20) DEFAULT 'unknown'::character varying NOT NULL,
    components jsonb DEFAULT '{}'::jsonb,
    confidence numeric(5,4),
    stream_id uuid NOT NULL,
    user_id character varying(50),
    username character varying(255) NOT NULL
);


--
-- Name: post_stream_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_stream_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    anomalies jsonb DEFAULT '[]'::jsonb,
    ccv_avg integer,
    ccv_peak integer,
    duration_ms bigint,
    erv_final integer,
    erv_percent_final numeric(5,2),
    generated_at timestamp(6) without time zone NOT NULL,
    signals_summary jsonb DEFAULT '{}'::jsonb,
    stream_id uuid NOT NULL,
    trust_index_final numeric(5,2)
);


--
-- Name: predictions_polls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.predictions_polls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ccv_at_time integer,
    event_type character varying(20) NOT NULL,
    participants_count integer NOT NULL,
    participation_ratio numeric(5,4),
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: raid_attributions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.raid_attributions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bot_score numeric(5,4),
    is_bot_raid boolean DEFAULT false NOT NULL,
    raid_viewers_count integer,
    signal_scores jsonb DEFAULT '{}'::jsonb,
    source_channel_id uuid,
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: recommendation_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recommendation_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    component character varying(30) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    cta_action character varying(100),
    display_order integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    expected_impact character varying(50),
    i18n_key character varying(100) NOT NULL,
    priority character varying(15) NOT NULL,
    rule_id character varying(10) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: rehabilitation_penalty_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rehabilitation_penalty_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    applied_at timestamp(6) without time zone NOT NULL,
    applied_stream_id uuid,
    channel_id uuid NOT NULL,
    clean_streams_at_resolve integer,
    created_at timestamp(6) without time zone NOT NULL,
    initial_penalty numeric(5,2) NOT NULL,
    required_clean_streams integer DEFAULT 15 NOT NULL,
    resolved_at timestamp(6) without time zone,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: score_disputes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.score_disputes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    reason text NOT NULL,
    resolution_at timestamp(6) without time zone,
    resolution_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    submitted_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    ip_address inet,
    is_active boolean DEFAULT true NOT NULL,
    token character varying(255) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_agent text,
    user_id uuid NOT NULL
);


--
-- Name: signal_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.signal_configurations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category character varying(50) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    param_name character varying(100) NOT NULL,
    param_value numeric(10,4) NOT NULL,
    signal_type character varying(50) NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: signals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.signals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category character varying(50),
    confidence numeric(5,4),
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    signal_type character varying(50) NOT NULL,
    stream_id uuid NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL,
    value numeric(10,4) NOT NULL,
    weight_in_ti numeric(5,4)
);


--
-- Name: streamer_ratings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streamer_ratings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    calculated_at timestamp(6) without time zone NOT NULL,
    channel_id uuid NOT NULL,
    confidence_level character varying(20),
    created_at timestamp(6) without time zone NOT NULL,
    decay_lambda numeric(5,4) DEFAULT 0.05 NOT NULL,
    rating_observed numeric(5,2),
    rating_score numeric(5,2) NOT NULL,
    streams_count integer DEFAULT 0 NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: streamer_reputations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streamer_reputations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    calculated_at timestamp(6) without time zone NOT NULL,
    channel_id uuid NOT NULL,
    engagement_consistency_score numeric(5,2),
    follower_quality_score numeric(5,2),
    growth_pattern_score numeric(5,2),
    pattern_history_score numeric(5,2)
);


--
-- Name: streams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.streams (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    avg_ccv integer DEFAULT 0,
    channel_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    duration_ms bigint,
    ended_at timestamp(6) without time zone,
    game_name character varying(255),
    is_mature boolean DEFAULT false NOT NULL,
    language character varying(10),
    merge_status character varying(20) DEFAULT 'separate'::character varying,
    merged_parts_count integer DEFAULT 1 NOT NULL,
    part_boundaries jsonb DEFAULT '[]'::jsonb NOT NULL,
    peak_ccv integer DEFAULT 0,
    started_at timestamp(6) without time zone NOT NULL,
    title text,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    billing_period_end timestamp(6) without time zone,
    cancelled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    plan_type character varying(20),
    price numeric(10,2),
    provider_subscription_id character varying(255),
    started_at timestamp(6) without time zone NOT NULL,
    tier character varying(20) DEFAULT 'free'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: team_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    role character varying DEFAULT 'member'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    team_owner_id uuid NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: tracked_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracked_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    added_at timestamp(6) without time zone NOT NULL,
    channel_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    tracking_enabled boolean DEFAULT true NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: tracking_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_login character varying(50) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    extension_install_id uuid,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid
);


--
-- Name: trends_daily_aggregates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trends_daily_aggregates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    date date NOT NULL,
    ti_avg numeric(5,2),
    ti_std numeric(5,2),
    ti_min numeric(5,2),
    ti_max numeric(5,2),
    erv_avg_percent numeric(5,2),
    erv_min_percent numeric(5,2),
    erv_max_percent numeric(5,2),
    ccv_avg integer,
    ccv_peak integer,
    streams_count integer DEFAULT 0 NOT NULL,
    botted_fraction numeric(4,3),
    classification_at_end character varying(30),
    categories jsonb DEFAULT '{}'::jsonb NOT NULL,
    signal_breakdown jsonb DEFAULT '{}'::jsonb NOT NULL,
    discovery_phase_score numeric(4,3),
    follower_ccv_coupling_r numeric(4,3),
    tier_change_on_day boolean DEFAULT false NOT NULL,
    is_best_stream_day boolean DEFAULT false NOT NULL,
    is_worst_stream_day boolean DEFAULT false NOT NULL,
    schema_version integer DEFAULT 2 NOT NULL,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (date);


--
-- Name: trends_daily_aggregates_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trends_daily_aggregates_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    date date NOT NULL,
    ti_avg numeric(5,2),
    ti_std numeric(5,2),
    ti_min numeric(5,2),
    ti_max numeric(5,2),
    erv_avg_percent numeric(5,2),
    erv_min_percent numeric(5,2),
    erv_max_percent numeric(5,2),
    ccv_avg integer,
    ccv_peak integer,
    streams_count integer DEFAULT 0 NOT NULL,
    botted_fraction numeric(4,3),
    classification_at_end character varying(30),
    categories jsonb DEFAULT '{}'::jsonb NOT NULL,
    signal_breakdown jsonb DEFAULT '{}'::jsonb NOT NULL,
    discovery_phase_score numeric(4,3),
    follower_ccv_coupling_r numeric(4,3),
    tier_change_on_day boolean DEFAULT false NOT NULL,
    is_best_stream_day boolean DEFAULT false NOT NULL,
    is_worst_stream_day boolean DEFAULT false NOT NULL,
    schema_version integer DEFAULT 2 NOT NULL,
    created_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT now() NOT NULL
);


--
-- Name: trust_index_histories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_index_histories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    calculated_at timestamp(6) without time zone NOT NULL,
    ccv integer,
    channel_id uuid NOT NULL,
    classification character varying(20),
    cold_start_status character varying(20),
    confidence numeric(5,4),
    erv_percent numeric(5,2),
    rehabilitation_bonus numeric(5,2) DEFAULT 0.0,
    rehabilitation_penalty numeric(5,2) DEFAULT 0.0,
    signal_breakdown jsonb DEFAULT '{}'::jsonb,
    stream_id uuid,
    trust_index_score numeric(5,2) NOT NULL,
    engagement_percentile_at_end numeric(5,2),
    engagement_consistency_percentile_at_end numeric(5,2),
    category_at_end character varying(100)
);


--
-- Name: user_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    banner_image_url text,
    created_at timestamp(6) without time zone,
    description text,
    followers_total integer,
    follows_total integer,
    is_affiliate boolean DEFAULT false NOT NULL,
    is_partner boolean DEFAULT false NOT NULL,
    last_broadcast_at timestamp(6) without time zone,
    last_updated_at timestamp(6) without time zone,
    profile_view_count integer,
    twitch_id character varying(50),
    username character varying(255) NOT NULL,
    videos_total_count integer
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    avatar_url text,
    created_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone,
    display_name character varying(255),
    email character varying(255),
    goal_tag character varying(20),
    locale character varying(5) DEFAULT 'en'::character varying NOT NULL,
    role character varying(20) DEFAULT 'viewer'::character varying NOT NULL,
    tier character varying(20) DEFAULT 'free'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    username character varying(255)
);


--
-- Name: visual_qa_channel_seeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visual_qa_channel_seeds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    seed_profile character varying(60) NOT NULL,
    seeded_at timestamp(6) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: COLUMN visual_qa_channel_seeds.seed_profile; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.visual_qa_channel_seeds.seed_profile IS 'Seeder preset (premium_tracked, streamer_with_rehab, etc.)';


--
-- Name: COLUMN visual_qa_channel_seeds.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.visual_qa_channel_seeds.metadata IS 'Counts of created rows per kind (streams, tda, tih, anomalies, tier_changes, rehab_events)';


--
-- Name: COLUMN visual_qa_channel_seeds.schema_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.visual_qa_channel_seeds.schema_version IS 'Bumped при breaking changes в seed profile structure';


--
-- Name: watchlist_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watchlist_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    added_at timestamp(6) without time zone DEFAULT now() NOT NULL,
    channel_id uuid NOT NULL,
    "position" integer,
    watchlist_id uuid NOT NULL
);


--
-- Name: watchlist_tags_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watchlist_tags_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    added_at timestamp(6) without time zone NOT NULL,
    channel_id uuid NOT NULL,
    notes text,
    tags jsonb DEFAULT '[]'::jsonb,
    watchlist_id uuid NOT NULL
);


--
-- Name: watchlists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watchlists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    name character varying(255) NOT NULL,
    "position" integer,
    team_owner_id uuid,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


--
-- Name: trends_daily_aggregates_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trends_daily_aggregates ATTACH PARTITION public.trends_daily_aggregates_default DEFAULT;


--
-- Name: flipper_features id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_features ALTER COLUMN id SET DEFAULT nextval('public.flipper_features_id_seq'::regclass);


--
-- Name: flipper_gates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_gates ALTER COLUMN id SET DEFAULT nextval('public.flipper_gates_id_seq'::regclass);


--
-- Name: anomalies anomalies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomalies
    ADD CONSTRAINT anomalies_pkey PRIMARY KEY (id);


--
-- Name: anomaly_attributions anomaly_attributions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_attributions
    ADD CONSTRAINT anomaly_attributions_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: attribution_sources attribution_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attribution_sources
    ADD CONSTRAINT attribution_sources_pkey PRIMARY KEY (id);


--
-- Name: auth_events auth_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_events
    ADD CONSTRAINT auth_events_pkey PRIMARY KEY (id);


--
-- Name: auth_providers auth_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_providers
    ADD CONSTRAINT auth_providers_pkey PRIMARY KEY (id);


--
-- Name: billing_events billing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_pkey PRIMARY KEY (id);


--
-- Name: ccv_snapshots ccv_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ccv_snapshots
    ADD CONSTRAINT ccv_snapshots_pkey PRIMARY KEY (id);


--
-- Name: channel_protection_configs channel_protection_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_protection_configs
    ADD CONSTRAINT channel_protection_configs_pkey PRIMARY KEY (id);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chatters_snapshots chatters_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chatters_snapshots
    ADD CONSTRAINT chatters_snapshots_pkey PRIMARY KEY (id);


--
-- Name: cross_channel_presences cross_channel_presences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_channel_presences
    ADD CONSTRAINT cross_channel_presences_pkey PRIMARY KEY (id);


--
-- Name: dismissed_recommendations dismissed_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dismissed_recommendations
    ADD CONSTRAINT dismissed_recommendations_pkey PRIMARY KEY (id);


--
-- Name: erv_estimates erv_estimates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erv_estimates
    ADD CONSTRAINT erv_estimates_pkey PRIMARY KEY (id);


--
-- Name: flipper_features flipper_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_features
    ADD CONSTRAINT flipper_features_pkey PRIMARY KEY (id);


--
-- Name: flipper_gates flipper_gates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_gates
    ADD CONSTRAINT flipper_gates_pkey PRIMARY KEY (id);


--
-- Name: follower_snapshots follower_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follower_snapshots
    ADD CONSTRAINT follower_snapshots_pkey PRIMARY KEY (id);


--
-- Name: health_score_categories health_score_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_score_categories
    ADD CONSTRAINT health_score_categories_pkey PRIMARY KEY (id);


--
-- Name: health_score_category_aliases health_score_category_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_score_category_aliases
    ADD CONSTRAINT health_score_category_aliases_pkey PRIMARY KEY (id);


--
-- Name: health_score_tiers health_score_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_score_tiers
    ADD CONSTRAINT health_score_tiers_pkey PRIMARY KEY (id);


--
-- Name: health_scores health_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scores
    ADD CONSTRAINT health_scores_pkey PRIMARY KEY (id);


--
-- Name: hs_tier_change_events hs_tier_change_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hs_tier_change_events
    ADD CONSTRAINT hs_tier_change_events_pkey PRIMARY KEY (id);


--
-- Name: known_bot_lists known_bot_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.known_bot_lists
    ADD CONSTRAINT known_bot_lists_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: pdf_reports pdf_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pdf_reports
    ADD CONSTRAINT pdf_reports_pkey PRIMARY KEY (id);


--
-- Name: per_user_bot_scores per_user_bot_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.per_user_bot_scores
    ADD CONSTRAINT per_user_bot_scores_pkey PRIMARY KEY (id);


--
-- Name: post_stream_reports post_stream_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_stream_reports
    ADD CONSTRAINT post_stream_reports_pkey PRIMARY KEY (id);


--
-- Name: predictions_polls predictions_polls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predictions_polls
    ADD CONSTRAINT predictions_polls_pkey PRIMARY KEY (id);


--
-- Name: raid_attributions raid_attributions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raid_attributions
    ADD CONSTRAINT raid_attributions_pkey PRIMARY KEY (id);


--
-- Name: recommendation_templates recommendation_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_templates
    ADD CONSTRAINT recommendation_templates_pkey PRIMARY KEY (id);


--
-- Name: rehabilitation_penalty_events rehabilitation_penalty_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rehabilitation_penalty_events
    ADD CONSTRAINT rehabilitation_penalty_events_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: score_disputes score_disputes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_disputes
    ADD CONSTRAINT score_disputes_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: signal_configurations signal_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signal_configurations
    ADD CONSTRAINT signal_configurations_pkey PRIMARY KEY (id);


--
-- Name: signals signals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signals
    ADD CONSTRAINT signals_pkey PRIMARY KEY (id);


--
-- Name: streamer_ratings streamer_ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streamer_ratings
    ADD CONSTRAINT streamer_ratings_pkey PRIMARY KEY (id);


--
-- Name: streamer_reputations streamer_reputations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streamer_reputations
    ADD CONSTRAINT streamer_reputations_pkey PRIMARY KEY (id);


--
-- Name: streams streams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streams
    ADD CONSTRAINT streams_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: team_memberships team_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_pkey PRIMARY KEY (id);


--
-- Name: tracked_channels tracked_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracked_channels
    ADD CONSTRAINT tracked_channels_pkey PRIMARY KEY (id);


--
-- Name: tracking_requests tracking_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracking_requests
    ADD CONSTRAINT tracking_requests_pkey PRIMARY KEY (id);


--
-- Name: trends_daily_aggregates trends_daily_aggregates_channel_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trends_daily_aggregates
    ADD CONSTRAINT trends_daily_aggregates_channel_id_date_key UNIQUE (channel_id, date);


--
-- Name: trends_daily_aggregates_default trends_daily_aggregates_default_channel_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trends_daily_aggregates_default
    ADD CONSTRAINT trends_daily_aggregates_default_channel_id_date_key UNIQUE (channel_id, date);


--
-- Name: trends_daily_aggregates trends_daily_aggregates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trends_daily_aggregates
    ADD CONSTRAINT trends_daily_aggregates_pkey PRIMARY KEY (id, date);


--
-- Name: trends_daily_aggregates_default trends_daily_aggregates_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trends_daily_aggregates_default
    ADD CONSTRAINT trends_daily_aggregates_default_pkey PRIMARY KEY (id, date);


--
-- Name: trust_index_histories trust_index_histories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_index_histories
    ADD CONSTRAINT trust_index_histories_pkey PRIMARY KEY (id);


--
-- Name: user_accounts user_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_accounts
    ADD CONSTRAINT user_accounts_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: visual_qa_channel_seeds visual_qa_channel_seeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_qa_channel_seeds
    ADD CONSTRAINT visual_qa_channel_seeds_pkey PRIMARY KEY (id);


--
-- Name: watchlist_channels watchlist_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_channels
    ADD CONSTRAINT watchlist_channels_pkey PRIMARY KEY (id);


--
-- Name: watchlist_tags_notes watchlist_tags_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_tags_notes
    ADD CONSTRAINT watchlist_tags_notes_pkey PRIMARY KEY (id);


--
-- Name: watchlists watchlists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlists
    ADD CONSTRAINT watchlists_pkey PRIMARY KEY (id);


--
-- Name: idx_anomalies_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomalies_stream_time ON public.anomalies USING btree (stream_id, "timestamp");


--
-- Name: idx_anomaly_attr_anomaly_confidence; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_attr_anomaly_confidence ON public.anomaly_attributions USING btree (anomaly_id, confidence DESC);


--
-- Name: idx_anomaly_attr_anomaly_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_anomaly_attr_anomaly_source ON public.anomaly_attributions USING btree (anomaly_id, source);


--
-- Name: idx_anomaly_attr_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_attr_source ON public.anomaly_attributions USING btree (source);


--
-- Name: idx_attr_sources_enabled_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attr_sources_enabled_priority ON public.attribution_sources USING btree (enabled, priority) WHERE (enabled = true);


--
-- Name: idx_attr_sources_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_attr_sources_source ON public.attribution_sources USING btree (source);


--
-- Name: idx_auth_events_ip_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_events_ip_time ON public.auth_events USING btree (ip_address, created_at);


--
-- Name: idx_auth_events_provider_result_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_events_provider_result_time ON public.auth_events USING btree (provider, result, created_at);


--
-- Name: idx_auth_events_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_events_user_time ON public.auth_events USING btree (user_id, created_at);


--
-- Name: idx_billing_events_provider_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_billing_events_provider_event ON public.billing_events USING btree (provider_event_id);


--
-- Name: idx_billing_events_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_billing_events_user_time ON public.billing_events USING btree (user_id, created_at);


--
-- Name: idx_bot_scores_stream_classification; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bot_scores_stream_classification ON public.per_user_bot_scores USING btree (stream_id, classification);


--
-- Name: idx_bot_scores_stream_username; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_bot_scores_stream_username ON public.per_user_bot_scores USING btree (stream_id, username);


--
-- Name: idx_ccv_snapshots_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ccv_snapshots_stream_time ON public.ccv_snapshots USING btree (stream_id, "timestamp");


--
-- Name: idx_channels_login; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_channels_login ON public.channels USING btree (login);


--
-- Name: idx_channels_non_utc_timezone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channels_non_utc_timezone ON public.channels USING btree (timezone) WHERE ((timezone)::text <> 'UTC'::text);


--
-- Name: idx_chat_messages_channel_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_channel_login ON public.chat_messages USING btree (channel_login);


--
-- Name: idx_chat_messages_channel_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_channel_time ON public.chat_messages USING btree (channel_login, "timestamp");


--
-- Name: idx_chat_messages_msg_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_msg_type ON public.chat_messages USING btree (msg_type);


--
-- Name: idx_chat_messages_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_stream_time ON public.chat_messages USING btree (stream_id, "timestamp");


--
-- Name: idx_chat_messages_stream_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_stream_username ON public.chat_messages USING btree (stream_id, username);


--
-- Name: idx_chatters_snapshots_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chatters_snapshots_stream_time ON public.chatters_snapshots USING btree (stream_id, "timestamp");


--
-- Name: idx_cross_channel_channel_stream; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cross_channel_channel_stream ON public.cross_channel_presences USING btree (channel_id, stream_id);


--
-- Name: idx_cross_channel_user_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_cross_channel_user_channel ON public.cross_channel_presences USING btree (username, channel_id);


--
-- Name: idx_dismissed_rec_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_dismissed_rec_uniq ON public.dismissed_recommendations USING btree (user_id, channel_id, rule_id);


--
-- Name: idx_erv_estimates_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_erv_estimates_stream_time ON public.erv_estimates USING btree (stream_id, "timestamp");


--
-- Name: idx_flipper_gates_feature_key_value; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_flipper_gates_feature_key_value ON public.flipper_gates USING btree (feature_key, key, value);


--
-- Name: idx_follower_snapshots_channel_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_follower_snapshots_channel_time ON public.follower_snapshots USING btree (channel_id, "timestamp");


--
-- Name: idx_health_scores_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_scores_channel ON public.health_scores USING btree (channel_id);


--
-- Name: idx_hs_cat_aliases_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hs_cat_aliases_category ON public.health_score_category_aliases USING btree (health_score_category_id);


--
-- Name: idx_hs_cat_aliases_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_hs_cat_aliases_name ON public.health_score_category_aliases USING btree (game_name_alias);


--
-- Name: idx_hs_categories_single_default; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_hs_categories_single_default ON public.health_score_categories USING btree (is_default) WHERE (is_default = true);


--
-- Name: idx_hs_channel_cat_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hs_channel_cat_time ON public.health_scores USING btree (channel_id, category, calculated_at DESC);


--
-- Name: idx_hs_tier_events_channel_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hs_tier_events_channel_type_time ON public.hs_tier_change_events USING btree (channel_id, event_type, occurred_at DESC);


--
-- Name: idx_hs_tier_events_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hs_tier_events_time ON public.hs_tier_change_events USING btree (occurred_at DESC);


--
-- Name: idx_known_bot_lists_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_known_bot_lists_source ON public.known_bot_lists USING btree (source);


--
-- Name: idx_known_bot_lists_username_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_known_bot_lists_username_source ON public.known_bot_lists USING btree (username, source);


--
-- Name: idx_notifications_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user ON public.notifications USING btree (user_id);


--
-- Name: idx_per_user_bot_scores_stream; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_per_user_bot_scores_stream ON public.per_user_bot_scores USING btree (stream_id);


--
-- Name: idx_predictions_polls_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_predictions_polls_stream_time ON public.predictions_polls USING btree (stream_id, "timestamp");


--
-- Name: idx_raid_attributions_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raid_attributions_stream_time ON public.raid_attributions USING btree (stream_id, "timestamp");


--
-- Name: idx_rehab_events_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rehab_events_active ON public.rehabilitation_penalty_events USING btree (channel_id) WHERE (resolved_at IS NULL);


--
-- Name: idx_rehab_events_channel_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rehab_events_channel_time ON public.rehabilitation_penalty_events USING btree (channel_id, applied_at DESC);


--
-- Name: idx_score_disputes_user_submitted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_score_disputes_user_submitted ON public.score_disputes USING btree (user_id, submitted_at);


--
-- Name: idx_sessions_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_user_active ON public.sessions USING btree (user_id, is_active);


--
-- Name: idx_signal_configs_type_category_param; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_signal_configs_type_category_param ON public.signal_configurations USING btree (signal_type, category, param_name);


--
-- Name: idx_signals_stream_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_signals_stream_time ON public.signals USING btree (stream_id, "timestamp");


--
-- Name: idx_signals_stream_type_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_signals_stream_type_timestamp ON public.signals USING btree (stream_id, signal_type, "timestamp");


--
-- Name: idx_streamer_reputations_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_streamer_reputations_channel ON public.streamer_reputations USING btree (channel_id);


--
-- Name: idx_streamer_reputations_channel_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_streamer_reputations_channel_latest ON public.streamer_reputations USING btree (channel_id, calculated_at DESC);


--
-- Name: idx_subscriptions_provider_sub_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_subscriptions_provider_sub_id ON public.subscriptions USING btree (provider_subscription_id);


--
-- Name: idx_tda_best_worst; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tda_best_worst ON ONLY public.trends_daily_aggregates USING btree (channel_id, is_best_stream_day, is_worst_stream_day) WHERE ((is_best_stream_day = true) OR (is_worst_stream_day = true));


--
-- Name: idx_tda_categories_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tda_categories_gin ON ONLY public.trends_daily_aggregates USING gin (categories jsonb_path_ops);


--
-- Name: idx_tda_discovery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tda_discovery ON ONLY public.trends_daily_aggregates USING btree (channel_id, discovery_phase_score) WHERE (discovery_phase_score IS NOT NULL);


--
-- Name: idx_tda_tier_change; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tda_tier_change ON ONLY public.trends_daily_aggregates USING btree (channel_id, tier_change_on_day) WHERE (tier_change_on_day = true);


--
-- Name: idx_team_memberships_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_memberships_owner_id ON public.team_memberships USING btree (team_owner_id);


--
-- Name: idx_team_memberships_user_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_team_memberships_user_owner ON public.team_memberships USING btree (user_id, team_owner_id);


--
-- Name: idx_ti_histories_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ti_histories_channel ON public.trust_index_histories USING btree (channel_id);


--
-- Name: idx_tih_qualifying_snapshots; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tih_qualifying_snapshots ON public.trust_index_histories USING btree (channel_id, engagement_percentile_at_end, engagement_consistency_percentile_at_end) WHERE ((engagement_percentile_at_end IS NOT NULL) AND (engagement_consistency_percentile_at_end IS NOT NULL));


--
-- Name: idx_tracking_requests_unique_guest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tracking_requests_unique_guest ON public.tracking_requests USING btree (channel_login, extension_install_id) WHERE (extension_install_id IS NOT NULL);


--
-- Name: idx_tracking_requests_unique_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tracking_requests_unique_user ON public.tracking_requests USING btree (channel_login, user_id) WHERE (user_id IS NOT NULL);


--
-- Name: idx_watchlists_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watchlists_team_id ON public.watchlists USING btree (team_owner_id);


--
-- Name: idx_watchlists_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watchlists_user ON public.watchlists USING btree (user_id);


--
-- Name: idx_wc_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wc_channel ON public.watchlist_channels USING btree (channel_id);


--
-- Name: idx_wc_watchlist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wc_watchlist ON public.watchlist_channels USING btree (watchlist_id);


--
-- Name: idx_wc_watchlist_channel_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_wc_watchlist_channel_uniq ON public.watchlist_channels USING btree (watchlist_id, channel_id);


--
-- Name: idx_wc_watchlist_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wc_watchlist_position ON public.watchlist_channels USING btree (watchlist_id, "position");


--
-- Name: index_anomalies_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anomalies_on_stream_id ON public.anomalies USING btree (stream_id);


--
-- Name: index_anomaly_attributions_on_anomaly_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anomaly_attributions_on_anomaly_id ON public.anomaly_attributions USING btree (anomaly_id);


--
-- Name: index_api_keys_on_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_keys_on_key_hash ON public.api_keys USING btree (key_hash);


--
-- Name: index_api_keys_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_keys_on_user_id ON public.api_keys USING btree (user_id);


--
-- Name: index_auth_providers_on_provider_and_provider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_auth_providers_on_provider_and_provider_id ON public.auth_providers USING btree (provider, provider_id);


--
-- Name: index_auth_providers_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_providers_on_user_id ON public.auth_providers USING btree (user_id);


--
-- Name: index_ccv_snapshots_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ccv_snapshots_on_stream_id ON public.ccv_snapshots USING btree (stream_id);


--
-- Name: index_ccv_snapshots_on_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ccv_snapshots_on_timestamp ON public.ccv_snapshots USING btree ("timestamp");


--
-- Name: index_channel_protection_configs_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_protection_configs_on_channel_id ON public.channel_protection_configs USING btree (channel_id);


--
-- Name: index_channels_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_channels_on_deleted_at ON public.channels USING btree (deleted_at);


--
-- Name: index_channels_on_is_monitored; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_channels_on_is_monitored ON public.channels USING btree (is_monitored);


--
-- Name: index_channels_on_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_channels_on_login ON public.channels USING btree (login);


--
-- Name: index_channels_on_login_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channels_on_login_unique ON public.channels USING btree (login);


--
-- Name: index_channels_on_twitch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channels_on_twitch_id ON public.channels USING btree (twitch_id);


--
-- Name: index_chat_messages_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_stream_id ON public.chat_messages USING btree (stream_id);


--
-- Name: index_chat_messages_on_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_timestamp ON public.chat_messages USING btree ("timestamp");


--
-- Name: index_chat_messages_on_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_username ON public.chat_messages USING btree (username);


--
-- Name: index_chatters_snapshots_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chatters_snapshots_on_stream_id ON public.chatters_snapshots USING btree (stream_id);


--
-- Name: index_dismissed_recommendations_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dismissed_recommendations_on_channel_id ON public.dismissed_recommendations USING btree (channel_id);


--
-- Name: index_dismissed_recommendations_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dismissed_recommendations_on_user_id ON public.dismissed_recommendations USING btree (user_id);


--
-- Name: index_erv_estimates_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_erv_estimates_on_stream_id ON public.erv_estimates USING btree (stream_id);


--
-- Name: index_flipper_features_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_flipper_features_on_key ON public.flipper_features USING btree (key);


--
-- Name: index_health_score_categories_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_score_categories_on_key ON public.health_score_categories USING btree (key);


--
-- Name: index_health_score_tiers_on_display_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_score_tiers_on_display_order ON public.health_score_tiers USING btree (display_order);


--
-- Name: index_health_score_tiers_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_health_score_tiers_on_key ON public.health_score_tiers USING btree (key);


--
-- Name: index_health_scores_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_health_scores_on_channel_id ON public.health_scores USING btree (channel_id);


--
-- Name: index_health_scores_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_health_scores_on_stream_id ON public.health_scores USING btree (stream_id);


--
-- Name: index_hs_tier_change_events_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_hs_tier_change_events_on_channel_id ON public.hs_tier_change_events USING btree (channel_id);


--
-- Name: index_hs_tier_change_events_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_hs_tier_change_events_on_stream_id ON public.hs_tier_change_events USING btree (stream_id);


--
-- Name: index_notifications_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_channel_id ON public.notifications USING btree (channel_id);


--
-- Name: index_notifications_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_stream_id ON public.notifications USING btree (stream_id);


--
-- Name: index_notifications_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id ON public.notifications USING btree (user_id);


--
-- Name: index_pdf_reports_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pdf_reports_on_channel_id ON public.pdf_reports USING btree (channel_id);


--
-- Name: index_pdf_reports_on_share_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pdf_reports_on_share_token ON public.pdf_reports USING btree (share_token);


--
-- Name: index_pdf_reports_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pdf_reports_on_user_id ON public.pdf_reports USING btree (user_id);


--
-- Name: index_per_user_bot_scores_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_per_user_bot_scores_on_stream_id ON public.per_user_bot_scores USING btree (stream_id);


--
-- Name: index_per_user_bot_scores_on_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_per_user_bot_scores_on_username ON public.per_user_bot_scores USING btree (username);


--
-- Name: index_post_stream_reports_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_post_stream_reports_on_stream_id ON public.post_stream_reports USING btree (stream_id);


--
-- Name: index_raid_attributions_on_source_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_raid_attributions_on_source_channel_id ON public.raid_attributions USING btree (source_channel_id);


--
-- Name: index_raid_attributions_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_raid_attributions_on_stream_id ON public.raid_attributions USING btree (stream_id);


--
-- Name: index_recommendation_templates_on_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_templates_on_enabled ON public.recommendation_templates USING btree (enabled);


--
-- Name: index_recommendation_templates_on_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recommendation_templates_on_rule_id ON public.recommendation_templates USING btree (rule_id);


--
-- Name: index_rehabilitation_penalty_events_on_applied_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rehabilitation_penalty_events_on_applied_stream_id ON public.rehabilitation_penalty_events USING btree (applied_stream_id);


--
-- Name: index_rehabilitation_penalty_events_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rehabilitation_penalty_events_on_channel_id ON public.rehabilitation_penalty_events USING btree (channel_id);


--
-- Name: index_score_disputes_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_score_disputes_on_channel_id ON public.score_disputes USING btree (channel_id);


--
-- Name: index_score_disputes_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_score_disputes_on_user_id ON public.score_disputes USING btree (user_id);


--
-- Name: index_sessions_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sessions_on_token ON public.sessions USING btree (token);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_signals_on_signal_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_signals_on_signal_type ON public.signals USING btree (signal_type);


--
-- Name: index_signals_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_signals_on_stream_id ON public.signals USING btree (stream_id);


--
-- Name: index_signals_on_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_signals_on_timestamp ON public.signals USING btree ("timestamp");


--
-- Name: index_streamer_ratings_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_streamer_ratings_on_channel_id ON public.streamer_ratings USING btree (channel_id);


--
-- Name: index_streams_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_streams_on_channel_id ON public.streams USING btree (channel_id);


--
-- Name: index_streams_on_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_streams_on_started_at ON public.streams USING btree (started_at);


--
-- Name: index_subscriptions_on_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_subscriptions_on_is_active ON public.subscriptions USING btree (is_active);


--
-- Name: index_subscriptions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_subscriptions_on_user_id ON public.subscriptions USING btree (user_id);


--
-- Name: index_team_memberships_on_team_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_memberships_on_team_owner_id ON public.team_memberships USING btree (team_owner_id);


--
-- Name: index_team_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_memberships_on_user_id ON public.team_memberships USING btree (user_id);


--
-- Name: index_tracked_channels_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracked_channels_on_channel_id ON public.tracked_channels USING btree (channel_id);


--
-- Name: index_tracked_channels_on_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracked_channels_on_subscription_id ON public.tracked_channels USING btree (subscription_id);


--
-- Name: index_tracked_channels_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracked_channels_on_user_id ON public.tracked_channels USING btree (user_id);


--
-- Name: index_tracked_channels_on_user_id_and_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tracked_channels_on_user_id_and_channel_id ON public.tracked_channels USING btree (user_id, channel_id);


--
-- Name: index_tracking_requests_on_channel_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracking_requests_on_channel_login ON public.tracking_requests USING btree (channel_login);


--
-- Name: index_trust_index_histories_on_calculated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trust_index_histories_on_calculated_at ON public.trust_index_histories USING btree (calculated_at);


--
-- Name: index_trust_index_histories_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trust_index_histories_on_channel_id ON public.trust_index_histories USING btree (channel_id);


--
-- Name: index_trust_index_histories_on_stream_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_trust_index_histories_on_stream_id ON public.trust_index_histories USING btree (stream_id);


--
-- Name: index_user_accounts_on_twitch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_accounts_on_twitch_id ON public.user_accounts USING btree (twitch_id);


--
-- Name: index_user_accounts_on_username; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_accounts_on_username ON public.user_accounts USING btree (username);


--
-- Name: index_users_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_deleted_at ON public.users USING btree (deleted_at);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_username; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_username ON public.users USING btree (username);


--
-- Name: index_visual_qa_channel_seeds_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_visual_qa_channel_seeds_on_channel_id ON public.visual_qa_channel_seeds USING btree (channel_id);


--
-- Name: index_visual_qa_channel_seeds_on_seed_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_visual_qa_channel_seeds_on_seed_profile ON public.visual_qa_channel_seeds USING btree (seed_profile);


--
-- Name: index_visual_qa_channel_seeds_on_seeded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_visual_qa_channel_seeds_on_seeded_at ON public.visual_qa_channel_seeds USING btree (seeded_at);


--
-- Name: index_watchlist_tags_notes_on_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlist_tags_notes_on_channel_id ON public.watchlist_tags_notes USING btree (channel_id);


--
-- Name: index_watchlist_tags_notes_on_watchlist_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlist_tags_notes_on_watchlist_id ON public.watchlist_tags_notes USING btree (watchlist_id);


--
-- Name: index_watchlists_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_watchlists_on_user_id ON public.watchlists USING btree (user_id);


--
-- Name: trends_daily_aggregates_defau_channel_id_discovery_phase_sc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trends_daily_aggregates_defau_channel_id_discovery_phase_sc_idx ON public.trends_daily_aggregates_default USING btree (channel_id, discovery_phase_score) WHERE (discovery_phase_score IS NOT NULL);


--
-- Name: trends_daily_aggregates_defau_channel_id_is_best_stream_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trends_daily_aggregates_defau_channel_id_is_best_stream_day_idx ON public.trends_daily_aggregates_default USING btree (channel_id, is_best_stream_day, is_worst_stream_day) WHERE ((is_best_stream_day = true) OR (is_worst_stream_day = true));


--
-- Name: trends_daily_aggregates_defau_channel_id_tier_change_on_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trends_daily_aggregates_defau_channel_id_tier_change_on_day_idx ON public.trends_daily_aggregates_default USING btree (channel_id, tier_change_on_day) WHERE (tier_change_on_day = true);


--
-- Name: trends_daily_aggregates_default_categories_gin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX trends_daily_aggregates_default_categories_gin_idx ON public.trends_daily_aggregates_default USING gin (categories jsonb_path_ops);


--
-- Name: trends_daily_aggregates_defau_channel_id_discovery_phase_sc_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tda_discovery ATTACH PARTITION public.trends_daily_aggregates_defau_channel_id_discovery_phase_sc_idx;


--
-- Name: trends_daily_aggregates_defau_channel_id_is_best_stream_day_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tda_best_worst ATTACH PARTITION public.trends_daily_aggregates_defau_channel_id_is_best_stream_day_idx;


--
-- Name: trends_daily_aggregates_defau_channel_id_tier_change_on_day_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tda_tier_change ATTACH PARTITION public.trends_daily_aggregates_defau_channel_id_tier_change_on_day_idx;


--
-- Name: trends_daily_aggregates_default_categories_gin_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tda_categories_gin ATTACH PARTITION public.trends_daily_aggregates_default_categories_gin_idx;


--
-- Name: trends_daily_aggregates_default_channel_id_date_key; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.trends_daily_aggregates_channel_id_date_key ATTACH PARTITION public.trends_daily_aggregates_default_channel_id_date_key;


--
-- Name: trends_daily_aggregates_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.trends_daily_aggregates_pkey ATTACH PARTITION public.trends_daily_aggregates_default_pkey;


--
-- Name: dismissed_recommendations fk_rails_00e5a41490; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dismissed_recommendations
    ADD CONSTRAINT fk_rails_00e5a41490 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: streamer_reputations fk_rails_029b8316b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streamer_reputations
    ADD CONSTRAINT fk_rails_029b8316b9 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: rehabilitation_penalty_events fk_rails_06433b9f21; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rehabilitation_penalty_events
    ADD CONSTRAINT fk_rails_06433b9f21 FOREIGN KEY (applied_stream_id) REFERENCES public.streams(id);


--
-- Name: predictions_polls fk_rails_0ac4737834; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predictions_polls
    ADD CONSTRAINT fk_rails_0ac4737834 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: watchlists fk_rails_0dc1a4cbcb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlists
    ADD CONSTRAINT fk_rails_0dc1a4cbcb FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: raid_attributions fk_rails_0e8bdde8ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raid_attributions
    ADD CONSTRAINT fk_rails_0e8bdde8ff FOREIGN KEY (source_channel_id) REFERENCES public.channels(id);


--
-- Name: signals fk_rails_1b0bbfbd04; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signals
    ADD CONSTRAINT fk_rails_1b0bbfbd04 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: dismissed_recommendations fk_rails_2459d0f2bc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dismissed_recommendations
    ADD CONSTRAINT fk_rails_2459d0f2bc FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: pdf_reports fk_rails_26c4e33150; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pdf_reports
    ADD CONSTRAINT fk_rails_26c4e33150 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: notifications fk_rails_2ed70277e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_2ed70277e1 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: api_keys fk_rails_32c28d0dc2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT fk_rails_32c28d0dc2 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chatters_snapshots fk_rails_32d97e2d9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chatters_snapshots
    ADD CONSTRAINT fk_rails_32d97e2d9d FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: streamer_ratings fk_rails_32ede96e03; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streamer_ratings
    ADD CONSTRAINT fk_rails_32ede96e03 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: tracked_channels fk_rails_330a942dd0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracked_channels
    ADD CONSTRAINT fk_rails_330a942dd0 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: ccv_snapshots fk_rails_33a842279f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ccv_snapshots
    ADD CONSTRAINT fk_rails_33a842279f FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: watchlist_channels fk_rails_38feae2486; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_channels
    ADD CONSTRAINT fk_rails_38feae2486 FOREIGN KEY (watchlist_id) REFERENCES public.watchlists(id) ON DELETE CASCADE;


--
-- Name: cross_channel_presences fk_rails_3f88463b83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_channel_presences
    ADD CONSTRAINT fk_rails_3f88463b83 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: team_memberships fk_rails_5aba9331a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_5aba9331a7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: pdf_reports fk_rails_67c0be818f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pdf_reports
    ADD CONSTRAINT fk_rails_67c0be818f FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: raid_attributions fk_rails_6cf04d5cdb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raid_attributions
    ADD CONSTRAINT fk_rails_6cf04d5cdb FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: auth_providers fk_rails_6e9f6a270f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_providers
    ADD CONSTRAINT fk_rails_6e9f6a270f FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: streams fk_rails_70e193d920; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.streams
    ADD CONSTRAINT fk_rails_70e193d920 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: cross_channel_presences fk_rails_77e1b0a7ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_channel_presences
    ADD CONSTRAINT fk_rails_77e1b0a7ba FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: team_memberships fk_rails_7a19a33572; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_7a19a33572 FOREIGN KEY (team_owner_id) REFERENCES public.users(id);


--
-- Name: post_stream_reports fk_rails_8e55a75df5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_stream_reports
    ADD CONSTRAINT fk_rails_8e55a75df5 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: billing_events fk_rails_8f884ad43e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT fk_rails_8f884ad43e FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: subscriptions fk_rails_933bdff476; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT fk_rails_933bdff476 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: health_scores fk_rails_9378684e98; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scores
    ADD CONSTRAINT fk_rails_9378684e98 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: visual_qa_channel_seeds fk_rails_95d02fab9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_qa_channel_seeds
    ADD CONSTRAINT fk_rails_95d02fab9d FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: trust_index_histories fk_rails_9670d86913; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_index_histories
    ADD CONSTRAINT fk_rails_9670d86913 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: per_user_bot_scores fk_rails_980f57f882; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.per_user_bot_scores
    ADD CONSTRAINT fk_rails_980f57f882 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: anomaly_attributions fk_rails_98480c7c25; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_attributions
    ADD CONSTRAINT fk_rails_98480c7c25 FOREIGN KEY (anomaly_id) REFERENCES public.anomalies(id);


--
-- Name: score_disputes fk_rails_9a1e53ee77; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_disputes
    ADD CONSTRAINT fk_rails_9a1e53ee77 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: tracked_channels fk_rails_a0d006541a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracked_channels
    ADD CONSTRAINT fk_rails_a0d006541a FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id);


--
-- Name: erv_estimates fk_rails_a13ad72ef9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erv_estimates
    ADD CONSTRAINT fk_rails_a13ad72ef9 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: anomalies fk_rails_a2525509a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomalies
    ADD CONSTRAINT fk_rails_a2525509a8 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: watchlist_tags_notes fk_rails_a550cc0b7c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_tags_notes
    ADD CONSTRAINT fk_rails_a550cc0b7c FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: tracked_channels fk_rails_a5bf6c15d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracked_channels
    ADD CONSTRAINT fk_rails_a5bf6c15d6 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: watchlist_channels fk_rails_a6c495be7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_channels
    ADD CONSTRAINT fk_rails_a6c495be7b FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: watchlist_tags_notes fk_rails_adc045947c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlist_tags_notes
    ADD CONSTRAINT fk_rails_adc045947c FOREIGN KEY (watchlist_id) REFERENCES public.watchlists(id);


--
-- Name: notifications fk_rails_b070176ef4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_b070176ef4 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: notifications fk_rails_b080fb4855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_b080fb4855 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: score_disputes fk_rails_b6947423e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_disputes
    ADD CONSTRAINT fk_rails_b6947423e9 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: health_scores fk_rails_b89b271741; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_scores
    ADD CONSTRAINT fk_rails_b89b271741 FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: trust_index_histories fk_rails_bade55114e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_index_histories
    ADD CONSTRAINT fk_rails_bade55114e FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: rehabilitation_penalty_events fk_rails_bd8054b565; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rehabilitation_penalty_events
    ADD CONSTRAINT fk_rails_bd8054b565 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: follower_snapshots fk_rails_c7b86ba473; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follower_snapshots
    ADD CONSTRAINT fk_rails_c7b86ba473 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: auth_events fk_rails_da594da8a2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_events
    ADD CONSTRAINT fk_rails_da594da8a2 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chat_messages fk_rails_dbe407105b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT fk_rails_dbe407105b FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: channel_protection_configs fk_rails_e373df528b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_protection_configs
    ADD CONSTRAINT fk_rails_e373df528b FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: watchlists fk_rails_e39d6f991a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watchlists
    ADD CONSTRAINT fk_rails_e39d6f991a FOREIGN KEY (team_owner_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: tracking_requests fk_rails_e848c98277; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracking_requests
    ADD CONSTRAINT fk_rails_e848c98277 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: hs_tier_change_events fk_rails_ec1656520a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hs_tier_change_events
    ADD CONSTRAINT fk_rails_ec1656520a FOREIGN KEY (stream_id) REFERENCES public.streams(id);


--
-- Name: hs_tier_change_events fk_rails_f05d027b30; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hs_tier_change_events
    ADD CONSTRAINT fk_rails_f05d027b30 FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: health_score_category_aliases fk_rails_fffaa4a855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_score_category_aliases
    ADD CONSTRAINT fk_rails_fffaa4a855 FOREIGN KEY (health_score_category_id) REFERENCES public.health_score_categories(id);


--
-- Name: trends_daily_aggregates trends_daily_aggregates_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.trends_daily_aggregates
    ADD CONSTRAINT trends_daily_aggregates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260425100003'),
('20260425100002'),
('20260425100001'),
('20260424100001'),
('20260422100002'),
('20260422100001'),
('20260421100002'),
('20260421100001'),
('20260420100005'),
('20260420100004'),
('20260420100003'),
('20260420100002'),
('20260420100001'),
('20260419100007'),
('20260419100006'),
('20260419100005'),
('20260419100004'),
('20260419100003'),
('20260419100002'),
('20260419100001'),
('20260417100011'),
('20260417100010'),
('20260417100009'),
('20260417100008'),
('20260417100007'),
('20260417100006'),
('20260417100005'),
('20260417100004'),
('20260417100003'),
('20260417100002'),
('20260417100001'),
('20260416200001'),
('20260416100003'),
('20260416100002'),
('20260416100001'),
('20260415200001'),
('20260415100004'),
('20260415100003'),
('20260415100002'),
('20260415100001'),
('20260402100001'),
('20260331300001'),
('20260331200001'),
('20260331100003'),
('20260331100002'),
('20260330400001'),
('20260330300001'),
('20260330200001'),
('20260330140001'),
('20260329140001'),
('20260328200001'),
('20260328100006'),
('20260328100005'),
('20260328100004'),
('20260328100003'),
('20260328100002'),
('20260328100001'),
('20260327100004'),
('20260327100003'),
('20260327100002'),
('20260327100001'),
('20260327000002'),
('20260327000001'),
('20260324000010'),
('20260324000009'),
('20260324000008'),
('20260324000007'),
('20260324000006'),
('20260324000005'),
('20260324000004'),
('20260324000003'),
('20260324000002'),
('20260324000001');

