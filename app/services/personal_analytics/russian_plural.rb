# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (M10 narrative): Russian plural-form selector. Rails core I18n даёт only :one/:other
  # (английская модель); rails-i18n gem НЕ установлен (Gemfile проверен). Минимальный helper для
  # одного-двух мест (reflection narrative + moments). EN locale получает корректные формы из
  # :one (count==1) / :many (else) — EN .yml mapping однообразный.
  module RussianPlural
    # https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html#ru — full CLDR.
    # one: mod10==1 && mod100!=11; few: mod10∈[2,3,4] && mod100∉[12,13,14]; many: остальное.
    def self.key(count)
      n = count.to_i.abs
      mod10 = n % 10
      mod100 = n % 100
      return :one if mod10 == 1 && mod100 != 11
      return :few if (2..4).cover?(mod10) && !(12..14).cover?(mod100)

      :many
    end

    # I18n.t(scope) ожидает hash {one:, few:, many:} (см. config/locales/pva.{ru,en}.yml).
    # Возвращает интерполированную строку. Fallback: :many → :other → count.to_s (никогда не падает).
    def self.translate(scope, count:, **vars)
      forms = I18n.t(scope, default: {})
      return count.to_s unless forms.is_a?(Hash)

      template = forms[key(count)] || forms[:many] || forms[:other]
      return count.to_s if template.blank?

      I18n.interpolate(template.to_s, vars.merge(count: count))
    end
  end
end
