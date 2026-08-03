#!/usr/bin/env python3
"""Every ```swift block in the DocC Recipe*.md articles must appear verbatim
in Examples/Recipes — the package CI compiles — so recipe documentation can
never drift from code that builds. Exit 1 on any orphaned snippet."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCC = ROOT / "Sources" / "TailscaleClient" / "TailscaleClient.docc"
RECIPES = ROOT / "Examples" / "Recipes"

FENCE = re.compile(r"```swift\n(.*?)```", re.S)


def normalize(text):
    return "\n".join(line.rstrip() for line in text.strip("\n").split("\n"))


def main():
    corpus = "\n\n".join(
        normalize(p.read_text()) for p in sorted(RECIPES.rglob("*.swift")))
    failures = 0
    checked = 0
    for article in sorted(DOCC.glob("Recipe*.md")):
        for match in FENCE.finditer(article.read_text()):
            checked += 1
            snippet = normalize(match.group(1))
            if snippet not in corpus:
                failures += 1
                first = snippet.split("\n", 1)[0]
                print(f"ORPHAN  {article.name}: snippet starting '{first}' "
                      "not found in Examples/Recipes sources")
    if failures:
        print(f"\n{failures} of {checked} recipe snippets drifted from the "
              "compiled sources — update Examples/Recipes or the article.")
        sys.exit(1)
    print(f"All {checked} recipe snippets match Examples/Recipes sources.")


if __name__ == "__main__":
    main()
