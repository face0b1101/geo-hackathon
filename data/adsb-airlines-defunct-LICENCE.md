# Defunct Airlines Dataset — Licence and Attribution

## Attribution

This dataset was derived from the "List of defunct airlines" articles on
Wikipedia, authored by Wikipedia contributors.

## Source Pages

- [List of defunct airlines of Africa](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Africa)
- [List of defunct airlines of the Americas](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_Americas)
- [List of defunct airlines of Asia](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Asia)
- [List of defunct airlines of Europe](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Europe)
- [List of defunct airlines of Oceania](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Oceania)
- [List of defunct airlines of India](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_India)
- [List of defunct airlines of the United States (A–C)](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_States_(A%E2%80%93C))
- [List of defunct airlines of the United States (D–I)](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_States_(D%E2%80%93I))
- [List of defunct airlines of the United States (J–P)](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_States_(J%E2%80%93P))
- [List of defunct airlines of the United States (Q–Z)](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_States_(Q%E2%80%93Z))
- [List of defunct airlines of the United Kingdom](https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_Kingdom)

## Changes Made

The original HTML tables were fetched via the [Jina Reader API](https://jina.ai),
filtered to entries with ICAO three-letter designator codes, and transformed
into NDJSON (newline-delimited JSON) format for use as an Elasticsearch lookup
index. Date fields were parsed where possible; all original text values are
preserved.

## Licence

This derived dataset is licensed under the **Creative Commons
Attribution-ShareAlike 4.0 International** licence (CC BY-SA 4.0).

Full licence text: <https://creativecommons.org/licenses/by-sa/4.0/>

## Scope

The CC BY-SA 4.0 licence applies only to the derived data file
(`adsb-airlines-defunct-data.ndjson`). The rest of this repository is not
subject to the ShareAlike obligation. Including adapted material in a
collection does not trigger ShareAlike on other works, per the
[CC BY-SA interpretation guidance](https://wiki.creativecommons.org/wiki/ShareAlike_interpretation).
