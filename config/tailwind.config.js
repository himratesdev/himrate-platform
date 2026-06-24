/** @type {import('tailwindcss').Config} */
// TASK-060 public landing. Tailwind v3 (matches Pencil export: cdn.tailwindcss.com).
// preflight:false — global reset disabled (export ships a tiny inline reset in the
// landing layout) so Tailwind base styles don't fight the bespoke design / API app.
module.exports = {
  content: [
    "./app/views/pages/**/*.{erb,html}",
    "./app/views/layouts/landing.html.erb",
    "./app/views/shared/**/*.{erb,html}",
    "./app/helpers/landing_helper.rb",
    "./app/assets/javascripts/landing/**/*.js",
  ],
  corePlugins: { preflight: false },
  theme: { extend: {} },
  plugins: [],
};
