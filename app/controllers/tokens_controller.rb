# frozen_string_literal: true

# Serves the palette as CSS custom properties at /tokens.css.
#
# The palette lives in Charts so the UI, the HTML deck and the PPTX export
# cannot drift apart (the Python server's _tokens_css did the same). Light
# tokens sit on :root; the dark set applies under the OS preference unless the
# page is stamped data-theme="light", and always under data-theme="dark", so
# the theme toggle can override the OS in either direction.
class TokensController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-store"
    render plain: self.class.css, content_type: "text/css"
  end

  def self.css
    light = Charts.css_tokens("light", selector: ":root")
    # css_tokens emits one "selector { ... }" block; only its body is wanted so
    # it can be wrapped twice below.
    dark = Charts.css_tokens("dark", selector: ":root")
    dark_body = dark.split("{", 2)[1].rpartition("}").first
    [
      light,
      "@media (prefers-color-scheme: dark) {",
      '  :root:where(:not([data-theme="light"])) {',
      dark_body,
      "  }",
      "}",
      ':root[data-theme="dark"] {',
      dark_body,
      "}",
      ""
    ].join("\n")
  end
end
