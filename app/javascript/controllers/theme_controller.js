import { Controller } from "@hotwired/stimulus"

// Light/dark toggle. /tokens.css carries both palettes: the dark one applies
// under the OS preference unless <html data-theme="light">, and always under
// data-theme="dark", so stamping the attribute overrides the OS either way.
// The choice persists in localStorage under the key the Python UI used.
const STORAGE_KEY = "argos-theme"

export default class extends Controller {
  connect() {
    const stored = this.read()
    if (stored) document.documentElement.dataset.theme = stored
  }

  toggle() {
    const current = document.documentElement.dataset.theme
      || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
    this.apply(current === "dark" ? "light" : "dark")
  }

  apply(theme) {
    document.documentElement.dataset.theme = theme
    // Storage can throw (private windows, blocked site data); the theme still
    // applies for this page.
    try { localStorage.setItem(STORAGE_KEY, theme) } catch (error) { /* not persisted */ }
  }

  read() {
    try { return localStorage.getItem(STORAGE_KEY) } catch (error) { return null }
  }
}
