// What the "Korrigieren" button over the transcript sends for a mark of the
// reader (K4b): the marked text, a little of the text the page shows before
// and after it, and how many characters of that text stand before it. The
// server finds the place in the stored transcript from these
// (Meetings::TranscriptMark) and refuses what it cannot place; this only cuts
// the pieces and decides whether the button shows at all.
//
// Characters, not UTF-16 units: Ruby counts code points, and an emoji before
// the mark would shift the offset by one per emoji otherwise. The context and
// the longest mark come from the page (Meetings::TranscriptMark::CONTEXT_LENGTH,
// GlossaryTerm::MAX_LENGTH), never as numbers of their own here.

// prefix, selected, suffix: the text of the transcript before, inside and
// after the mark, as the browser holds it (Range#toString). null when there is
// nothing to correct: a blank mark, one over a line break, one too long.
export function buildMark({ prefix, selected, suffix }, { context, maxLength }) {
  const text = String(selected ?? "")
  const core = text.trim()
  if (core === "" || /[\r\n]/.test(core) || [...core].length > maxLength) return null

  const start = text.indexOf(core)
  const before = [...(String(prefix ?? "") + text.slice(0, start))]
  const after = [...(text.slice(start + core.length) + String(suffix ?? ""))]
  return {
    text: core,
    before: before.slice(Math.max(before.length - context, 0)).join(""),
    after: after.slice(0, context).join(""),
    offset: before.length
  }
}

// The query of the dialog's address for a mark and the digest of the
// transcript the page shows.
export function markQuery(mark, digest) {
  const query = new URLSearchParams()
  for (const key of ["text", "before", "after", "offset"]) query.append(`mark[${key}]`, String(mark[key]))
  query.append("digest", digest)
  return query.toString()
}

// The fields of the dialog its count is asked with, out of the form's entries
// ([name, value] pairs): the mark, the digest, the opening and the heard form.
// Nothing else, the authenticity token least of all: a GET puts it in the address.
const COUNT_FIELDS = /^(?:mark\[(?:text|before|after|offset)\]|digest|modal_token|term_correction\[heard\])$/

export function countQuery(entries) {
  const query = new URLSearchParams()
  for (const [name, value] of entries) {
    if (COUNT_FIELDS.test(name) && typeof value === "string") query.append(name, value)
  }
  return query.toString()
}

// The address a base address gets with a query, whether or not it has one.
export function withQuery(base, query) {
  return `${base}${base.includes("?") ? "&" : "?"}${query}`
}
