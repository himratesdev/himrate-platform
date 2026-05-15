# HimRate Brand Assets

Logo + brand assets для HimRate (Chrome Extension + SaaS Platform).

## Источник

Logo создан PO в QuiverAI (https://quiver.ai) — 2026-05-16. 3 colorway варианта одного и того же mark + wordmark.

## Mark interpretation

Mark изображает человека сидящего перед монитором в наушниках — символ для «audience analysis / stream monitoring».

## Файлы

### Horizontal logos (mark + wordmark)

| File | Background | Mark color | Text color | Use case |
|---|---|---|---|---|
| `logo-horizontal-magenta.svg` | cream `#FFF4F2` | magenta `#C35FA5` | magenta `#C35FA5` | Default light theme (landing, dashboards, footers) |
| `logo-square-gradient.svg` | gradient `#A752E0`→`#B575ED` | white `#FFFFFF` | dark purple `#441068` | **PRIMARY** social media tile + CWS promo tile (216×144) |
| `logo-horizontal-coral.svg` | cream `#FFFBEE` | black `#010101` | coral `#E84C3F` | Accent/warm variant (e.g. email headers, sponsored content) |

### Mark only (без wordmark) — для icons/favicons

| File | Color | Use case |
|---|---|---|
| `logo-mark-color.svg` | magenta `#C35FA5` | Дefault icon-only (chrome extension, favicon, app badges) |
| `logo-mark-mono-black.svg` | black `#000000` | Invoices, legal docs, single-color print |
| `logo-mark-mono-white.svg` | white `#FFFFFF` | Dark backgrounds (night theme, video overlays, dark hero sections) |
| `favicon.svg` | magenta `#C35FA5` | Browser tab favicon (`<link rel="icon" type="image/svg+xml">`) |

## Chrome Extension icons

В `himrate-extension/public/icons/`:
- `icon16.svg` — toolbar icon (small)
- `icon48.svg` — extension management page
- `icon128.svg` — Chrome Web Store listing

Все 3 = mark only (magenta), различаются только атрибутом `width`/`height`. Chrome MV3 manifest поддерживает SVG напрямую — PNG не нужны.

## Brand colors (canonical)

```
Primary magenta:        #C35FA5
Dark purple (text):     #441068
Light purple gradient:  #A752E0 → #B575ED
Accent coral:           #E84C3F
Black:                  #000000 / #010101
White:                  #FFFFFF
Cream BG (warm):        #FFF4F2 / #FFFBEE
```

## Где использовать какой вариант

| Context | File |
|---|---|
| Rails Landing header | `logo-horizontal-magenta.svg` |
| Rails Dashboard sidebar | `logo-mark-color.svg` (icon only, экономия места) |
| Email transactional template | `logo-horizontal-magenta.svg` |
| CWS promo tile (1280×800, 440×280) | `logo-square-gradient.svg` (need rescale) |
| Social media preview (OG/Twitter cards) | `logo-square-gradient.svg` |
| Dark mode UI | `logo-mark-mono-white.svg` |
| Legal/billing PDF | `logo-mark-mono-black.svg` |
| Chrome Extension manifest icons | `himrate-extension/public/icons/icon{16,48,128}.svg` |
| Browser tab favicon | `favicon.svg` |

## PNG conversion (если понадобится)

ImageMagick (`magick`) установлен. Конверсия:
```bash
magick -background none -density 300 logo-mark-color.svg -resize 128x128 logo-mark-color-128.png
```

Для CWS promo tiles (raster required):
```bash
magick -background none -density 300 logo-square-gradient.svg -resize 1280x800 cws-promo-1280.png
magick -background none -density 300 logo-square-gradient.svg -resize 440x280 cws-promo-440.png
```

## Updates

- 2026-05-16: Initial drafts (3 colorway variants from QuiverAI) + mark extraction (color/mono-black/mono-white) + favicon.svg + Extension icons replacement.
