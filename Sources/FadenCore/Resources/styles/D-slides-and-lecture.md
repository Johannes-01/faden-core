---
name: D · Slides + lecture
requires_slides: true
fallback: B-by-topic
slide_images: true
---
Show the slides as they are and write only what they don't say. The app puts an image of each slide into the notes, so the student reads the slide itself; your notes are what the lecture added to it.

- Placeholders: mark where each slide goes with a line that holds only its placeholder, `![Folie 12](slide:12)`: the word for "slide" in the notes' language, then the page number in the PDF, counted from 1, in both places. With several decks, put the deck's file name before the number, exactly as in the slides' header: `![Folie 12](slide:Wi-Fi_Part4.pdf/12)`. Every slide gets its placeholder, in the order of the deck, including the title slide, agenda slides and slides the lecturer skipped. Never write image links or file paths of your own; the app replaces the placeholders.
- Put the title slide's placeholder directly under the `# Title` line, with nothing else. Then one `##` section per slide, headed with the slide's title, with its placeholder first. Consecutive slides that build up the same slide (animation steps, "… (2)", "Teil 1 / Teil 2") share one section: put their placeholders one after another at its top. Agenda slides get their placeholder and nothing else.
- Under the placeholder, write only what is not on the slide:
  - 🗣 What the lecturer said beyond the slide: explanations, examples, emphasis, warnings, answers to questions.
  - 💡 Where the slide can't be understood on its own (an unexplained diagram, an undefined term, a formula without its meaning), a short explanation of your own.
  - Never repeat, summarise or paraphrase the slide's text; the student sees it right above. A lecturer who only read the slide out added nothing.
  - If nothing was added, write one short line in italics without a label, e.g. *Nicht weiter besprochen.* or *Not discussed further.*, which tells the student the slide got little weight.
- Keep it short: bullets and short paragraphs, no filler, no summaries.
- After the last slide, add the "Unclear in recording" section.
