import { Controller } from "@hotwired/stimulus"

// "Pin to deck": a passage or snippet becomes evidence in a pitch book's
// appendix (Pitchbooks.add_evidence!). Port of openPinDialog and the pin-form
// handler in argos/static/app.js.
//
// The dialog markup is app/views/shared/_pin_dialog.html.erb. Pin buttons
// anywhere inside the controller's element carry the quote and ids as action
// params:
//   <button data-action="pin-dialog#open"
//           data-pin-dialog-quote-param="…" data-pin-dialog-document-id-param="12"
//           data-pin-dialog-chunk-id-param="345">Pin to deck</button>
// Submitting POSTs evidence[quote|document_id|chunk_id|note] to
// /pitchbooks/:id/evidences for the chosen book; the redirect back carries the
// "Pinned to the deck appendix." toast the Python UI showed. The quick toast
// below is kept for the one case decided here: no pitch book to pin to.
export default class extends Controller {
  static targets = ["dialog", "form", "quote", "quoteField", "documentField", "chunkField", "book", "note", "confirm"]

  open({ params }) {
    if (!this.hasBookTarget || this.bookTarget.options.length === 0) {
      this.toast("Generate a pitch book first, then pin evidence to it.")
      return
    }
    const quote = String(params.quote || "").trim()
    this.quoteTarget.textContent = quote
    this.quoteFieldTarget.value = quote
    this.documentFieldTarget.value = params.documentId ?? ""
    this.chunkFieldTarget.value = params.chunkId ?? ""
    this.noteTarget.value = ""
    this.retarget()
    this.dialogTarget.showModal()
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  // The form's action follows the selected pitch book, so it also works as
  // a plain form post.
  retarget() {
    const option = this.bookTarget.selectedOptions[0]
    if (option?.dataset.url) this.formTarget.action = option.dataset.url
  }

  // The form submits normally (through Turbo): EvidencesController#create
  // redirects back to this page with its own flash, so a failure is reported
  // as such rather than as a pin that never happened.
  submit(event) {
    this.retarget()
    if (!this.formTarget.action || this.formTarget.action.endsWith("#")) {
      event.preventDefault()
      this.toast("Choose a pitch book first.")
      return
    }
    if (this.hasConfirmTarget) this.confirmTarget.disabled = true
  }

  toast(message) {
    const node = document.getElementById("toast")
    if (!node) return
    // The layout's flash toast fades by CSS animation; drop those classes so
    // this message shows for its own 3.2 seconds.
    node.classList.remove("flash", "alert")
    node.textContent = message
    node.hidden = false
    clearTimeout(this.toastTimer)
    this.toastTimer = setTimeout(() => { node.hidden = true }, 3200)
  }

  disconnect() {
    clearTimeout(this.toastTimer)
  }
}
