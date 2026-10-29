# Book word counts for Stats fun facts

Verified on October 29, 2026. Each count comes directly from the named book's Standard Ebooks page, both its displayed word count and its `schema:wordCount` metadata. The pages were fetched successfully as XHTML when the web reader could not parse that content type.

These are edition-specific counts, not universal totals. Translations, front matter, revisions and counting rules can change them. War and Peace uses Louise and Aylmer Maude's translation. The app always says "about" and rounds comparisons. No reading or typing speeds come from these sources.

| Book | Words in this edition | Source |
| --- | ---: | --- |
| A Christmas Carol | 28,626 | [Standard Ebooks](https://standardebooks.org/ebooks/charles-dickens/a-christmas-carol) |
| The Call of the Wild | 31,792 | [Standard Ebooks](https://standardebooks.org/ebooks/jack-london/the-call-of-the-wild) |
| The Great Gatsby | 48,465 | [Standard Ebooks](https://standardebooks.org/ebooks/f-scott-fitzgerald/the-great-gatsby) |
| Frankenstein | 77,898 | [Standard Ebooks](https://standardebooks.org/ebooks/mary-shelley/frankenstein) |
| Pride and Prejudice | 121,970 | [Standard Ebooks](https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice) |
| Jane Eyre | 186,958 | [Standard Ebooks](https://standardebooks.org/ebooks/charlotte-bronte/jane-eyre) |
| Moby-Dick | 211,202 | [Standard Ebooks](https://standardebooks.org/ebooks/herman-melville/moby-dick) |
| War and Peace | 563,500 | [Standard Ebooks](https://standardebooks.org/ebooks/leo-tolstoy/war-and-peace/louise-maude_aylmer-maude) |

The table is kept beside the same source URLs in `Sources/VoiceCore/StatsFunFacts.swift`. The app shows at most two book comparisons, choosing the closest book below the all-time word count and the closest above it. Below the shortest book or above the longest, it shows one.

At the brief's real total of 39,712 words, the book sentences are:

- You've spoken about 1.2 times as many words as The Call of the Wild.
- You've spoken about 80% of the words in The Great Gatsby.

The longest-day and total-talking-time sentences use only the daily stats already stored on this Mac. Engines are combined for the same day. Talking time is displayed in whole minutes, with "less than a minute" for shorter totals.
