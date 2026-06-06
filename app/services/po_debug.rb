# frozen_string_literal: true

# PoDebug — internal real-time observability surface for the Product Owner.
#
# Renders a single dashboard at /dashboard/po-debug with 7 blocks of live data
# tied to the PO's own Twitch channel. Also exposes a JSON endpoint for the T1
# autonomous lane to poll the same data while performing VPS consolidation work.
#
# Not a customer-facing product feature. Behind Flipper flag :po_debug_dashboard.
# Auth = HTTP Basic Auth (single PO credentials in ENV).
#
# v0.1 (Hot-Lite): Blocks 1 (stream), 4 (queues), 5 (vps) wired.
#                  Blocks 2, 3, 6, 7 stubbed with "Coming in v1.0" placeholder.
# v1.0 fills the 4 stubs + adds ActionCable broadcast + full spec coverage.
module PoDebug
  CACHE_TTL = 5.seconds
  FLIPPER_FLAG = :po_debug_dashboard
end
