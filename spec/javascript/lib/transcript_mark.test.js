// What: the pieces the transcript's "Korrigieren" button sends for a mark (K4b).
// Type: node:test unit spec, no browser.
// Why: the server finds the place from the mark, its context and its offset
//   in the text the page shows (Meetings::TranscriptMark). An offset in UTF-16
//   units, whitespace kept in the mark, or a context cut in the middle of an
//   emoji would make it refuse marks it could place, or pick another place.
import { test } from "node:test"
import assert from "node:assert/strict"
import { buildMark, countQuery, markQuery, withQuery } from "../../../app/javascript/lib/transcript_mark.js"

const limits = { context: 40, maxLength: 255 }

test("cuts the mark, its context and its offset in characters", () => {
  const mark = buildMark({ prefix: "Anna: Grüße 👋 und ", selected: "Lalabeis", suffix: " heute." }, limits)

  assert.deepEqual(mark, { text: "Lalabeis", before: "Anna: Grüße 👋 und ", after: " heute.", offset: 18 })
})

test("moves whitespace around the mark into the context", () => {
  const mark = buildMark({ prefix: "Ben:", selected: " Lalabeis ", suffix: "kann" }, limits)

  assert.deepEqual(mark, { text: "Lalabeis", before: "Ben: ", after: " kann", offset: 5 })
})

test("keeps at most the context on each side, never half a character", () => {
  const prefix = "x".repeat(50) + "😀"
  const mark = buildMark({ prefix, selected: "Lalabeis", suffix: "😀".repeat(60) }, { context: 5, maxLength: 255 })

  assert.equal(mark.before, "xxxx😀")
  assert.equal(mark.after, "😀😀😀😀😀")
  assert.equal(mark.offset, 51)
})

test("offers nothing for a blank mark, one over a line break, or one too long", () => {
  assert.equal(buildMark({ prefix: "", selected: "  ", suffix: "" }, limits), null)
  assert.equal(buildMark({ prefix: "", selected: "Lala\nbeis", suffix: "" }, limits), null)
  assert.equal(buildMark({ prefix: "", selected: "x".repeat(256), suffix: "" }, limits), null)
  assert.notEqual(buildMark({ prefix: "", selected: "😀".repeat(255), suffix: "" }, limits), null)
})

test("puts the mark and the digest into the dialog's address", () => {
  const query = markQuery({ text: "Lala & Beis", before: "a", after: "b", offset: 3 }, "f".repeat(64))

  assert.equal(withQuery("/m/term_correction/new", query),
    `/m/term_correction/new?mark%5Btext%5D=Lala+%26+Beis&mark%5Bbefore%5D=a&mark%5Bafter%5D=b&mark%5Boffset%5D=3&digest=${"f".repeat(64)}`)
  assert.equal(withQuery("/m/count?x=1", "a=b"), "/m/count?x=1&a=b")
})

test("asks the count with the mark, the digest, the opening and the heard form only", () => {
  const entries = [
    ["authenticity_token", "geheim"], ["modal_token", "abcd"], ["mark[text]", "Lalabeis"], ["mark[offset]", "4"],
    ["digest", "d"], ["term_correction[heard]", "Lala beis"], ["term_correction[correct]", "Lalabase"], ["scope", "here"]
  ]

  assert.equal(countQuery(entries),
    "modal_token=abcd&mark%5Btext%5D=Lalabeis&mark%5Boffset%5D=4&digest=d&term_correction%5Bheard%5D=Lala+beis")
})
