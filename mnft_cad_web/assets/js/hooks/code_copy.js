// Clipboard copy for rendered code blocks in the chat transcript. The button
// carries data-target pointing at the <pre> whose text should be copied.
// Feedback is local ("copied!") and self-reverting; failures are silent —
// the user can still select the text manually.
export const CodeCopy = {
  mounted() {
    this.el.addEventListener("click", () => {
      const pre = document.getElementById(this.el.dataset.target)
      if (!pre || !navigator.clipboard) return
      navigator.clipboard.writeText(pre.textContent).then(() => {
        const original = this.el.textContent
        this.el.textContent = "copied!"
        setTimeout(() => (this.el.textContent = original), 1200)
      })
    })
  },
}
