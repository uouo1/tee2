import { Controller } from "@hotwired/stimulus"

// Comparable-company chips on the pitch-book forms. Port of renderCompPicker
// in argos/static/app.js.
//
// Two markups are supported, so the forms work without JavaScript either way:
//
// * checkbox chips (app/views/pitchbooks): a <label class="chip"> around a
//   checkbox with data-action="comp-picker#toggle"; the checkbox is the form
//   value and the label's aria-pressed follows it for the chip styling;
// * button chips (app/views/shared/_comp_picker.html.erb): a <button
//   class="chip" data-comp-picker-target="chip" data-ticker="X"> paired with a
//   hidden comp_tickers[] input (data-comp-picker-target="input") that is
//   disabled unless the chip is pressed.
//
// The target-company <select> is either a `target` target or named by the
// `targetSelect` value (a CSS selector). Changing it hides that company's own
// chip and re-presses the comps suggested by
// GET /api/companies/:ticker/suggest-comps.
export default class extends Controller {
  static targets = ["chip", "input", "target"]
  static values = {
    targetSelect: String,
    suggestUrl: { type: String, default: "/api/companies/:ticker/suggest-comps" },
  }

  connect() {
    this.select = this.hasTargetTarget
      ? this.targetTarget
      : (this.hasTargetSelectValue && this.targetSelectValue ? document.querySelector(this.targetSelectValue) : null)
    this.onTargetChange = () => this.retarget()
    this.select?.addEventListener("change", this.onTargetChange)
  }

  disconnect() {
    this.select?.removeEventListener("change", this.onTargetChange)
  }

  toggle(event) {
    const node = event.currentTarget
    if (node.type === "checkbox") {
      // The browser already flipped the box; mirror it on the chip.
      node.closest(".chip")?.setAttribute("aria-pressed", String(node.checked))
      return
    }
    this.press(node.dataset.ticker, node.getAttribute("aria-pressed") !== "true")
  }

  // Every chip as {ticker, set(pressed), hide(hidden)}, whichever markup.
  chips() {
    const buttons = this.chipTargets.map((chip) => ({
      ticker: chip.dataset.ticker,
      set: (pressed) => this.press(chip.dataset.ticker, pressed),
      hide: (hidden) => { chip.hidden = hidden },
    }))
    const boxes = Array.from(this.element.querySelectorAll('input[type="checkbox"][data-action~="comp-picker#toggle"]'))
      .map((box) => ({
        ticker: box.value,
        set: (pressed) => {
          box.checked = pressed
          box.closest(".chip")?.setAttribute("aria-pressed", String(pressed))
        },
        hide: (hidden) => { (box.closest(".chip") || box).hidden = hidden },
      }))
    return buttons.concat(boxes)
  }

  press(ticker, pressed) {
    this.chipTargets.filter((chip) => chip.dataset.ticker === ticker)
      .forEach((chip) => chip.setAttribute("aria-pressed", String(pressed)))
    this.inputTargets.filter((input) => input.value === ticker)
      .forEach((input) => { input.disabled = !pressed })
  }

  async retarget() {
    const target = this.select?.value
    if (!target) return
    const chips = this.chips()
    // A company is never its own comparable.
    chips.forEach((chip) => {
      const own = chip.ticker === target
      chip.hide(own)
      if (own) chip.set(false)
    })
    try {
      const url = this.suggestUrlValue.replace(":ticker", encodeURIComponent(target))
      const response = await fetch(url, { headers: { "Accept": "application/json" } })
      if (!response.ok) return
      const payload = await response.json()
      const suggested = new Set(payload.comps || [])
      chips.forEach((chip) => { if (chip.ticker !== target) chip.set(suggested.has(chip.ticker)) })
    } catch (error) {
      // Suggestions are a convenience; the chips still toggle by hand.
    }
  }
}
