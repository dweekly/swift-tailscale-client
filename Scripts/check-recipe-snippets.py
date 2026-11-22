#!/usr/bin/env python3
"""Every ```swift block in the DocC Recipe*.md articles must appear verbatim
in a package CI compiles, so recipe documentation can never drift from code
that builds. Most articles quote Examples/Recipes; the articles listed in
SOURCES_BY_ARTICLE quote the package named there instead. Exit 1 on any
orphaned snippet.

`--self-test` is the negative control: it adds a word to a real
snippet of every article that has one and confirms the check reports it."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCC = ROOT / "Sources" / "TailscaleClient" / "TailscaleClient.docc"
RECIPES = ROOT / "Examples" / "Recipes"
# Articles whose snippets come from a package other than Examples/Recipes.
SOURCES_BY_ARTICLE = {
    "RecipePeerDiagnostics.md": ROOT / "Examples" / "PeerDiagnostics" / "Sources",
}

FENCE = re.compile(r"```swift\n(.*?)```", re.S)
_corpora = {}


def normalize(text):
    return "\n".join(line.rstrip() for line in text.strip("\n").split("\n"))


def corpus_for(article_name):
    root = SOURCES_BY_ARTICLE.get(article_name, RECIPES)
    if root not in _corpora:
        _corpora[root] = "\n\n".join(
            normalize(p.read_text()) for p in sorted(root.rglob("*.swift")))
    return root, _corpora[root]


def orphans(article_name, text):
    """Returns (snippets checked, [(first line, source root)]) for one article."""
    root, corpus = corpus_for(article_name)
    snippets = [normalize(m.group(1)) for m in FENCE.finditer(text)]
    found = [(s.split("\n", 1)[0], root.relative_to(ROOT))
             for s in snippets if s not in corpus]
    return len(snippets), found


def check():
    failures = 0
    checked = 0
    for article in sorted(DOCC.glob("Recipe*.md")):
        count, found = orphans(article.name, article.read_text())
        checked += count
        for first, root in found:
            failures += 1
            print(f"ORPHAN  {article.name}: snippet starting '{first}' "
                  f"not found under {root}")
    if failures:
        print(f"\n{failures} of {checked} recipe snippets drifted from the "
              "compiled sources — update the sources or the article.")
        sys.exit(1)
    print(f"All {checked} recipe snippets match their compiled sources.")


def self_test():
    """Drifts the first snippet of each article by one word; every drift
    must be reported, or a passing check proves nothing."""
    tested = []
    for article in sorted(DOCC.glob("Recipe*.md")):
        text = article.read_text()
        match = FENCE.search(text)
        if not match:
            continue
        body = match.group(1)
        # Words added to the end of the first line survive normalization.
        drifted = body.replace("\n", " drift\n", 1)
        _, found = orphans(article.name, text.replace(body, drifted, 1))
        if not found:
            print(f"SELF-TEST FAILED  {article.name}: a drifted snippet "
                  "was not reported")
            sys.exit(1)
        tested.append(article.name)
    missing = set(SOURCES_BY_ARTICLE) - set(tested)
    if missing:
        print(f"SELF-TEST FAILED  no snippets found in {sorted(missing)}")
        sys.exit(1)
    print(f"Self-test passed: a one-word drift was reported in each of "
          f"{len(tested)} articles.")


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        self_test()
    else:
        check()
