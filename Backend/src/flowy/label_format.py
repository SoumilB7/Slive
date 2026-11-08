"""Step 4 of "Slive Custom 4": format a 3-way consensus label.

The consensus label (step 1-3, ``label_consensus``) is already the right
words; this step makes it read like written text — punctuation, filler and
restarts removed, lists and paragraphs where the speaker asked for them —
and then checks in code that nothing else changed:

  4.0 skip   the training gate already rejects the label (agreement < 0.8 or
             < 4 words) — no call, ``skipped``;
  4.1 flag   ``STRUCTURE: allowed`` only on a spoken cue (a count, first…
             second, a lead-in list, "new line"…) or a long message;
  4.2 call   gpt-5.5, JSON reply ``{"formatted"}``, five few-shot turns;
  4.3 verify every word-level difference must be an allowed edit class and
             touch ≤ 15% of the words, else ``rejected:<reason>``.

Ported 1:1 from the formatter bench Soumil approved (Nov 9 2026,
z-docs/training/formatter-bench/fmt.py + system.txt): the rules and the
prompt are the measured ones — change them there first, re-run the bench,
then here.

Same per-request key model as the consensus labeler: the OpenAI key travels
with the request and nothing is stored server-side.
"""

from __future__ import annotations

import asyncio
import difflib
import json
import logging
import re
from typing import Any

import httpx

# Retries and fatal errors work exactly like the consensus calls'.
from flowy.label_consensus import MAX_RETRIES, LabelFatalError, _is_quota_error, _retry_delay
from flowy.util import truncate

logger = logging.getLogger("flowy.label_format")

CHAT_URL = "https://api.openai.com/v1/chat/completions"
MODEL = "gpt-5.5"
#: One chat call can think for a while on a long message.
TIMEOUT_SECONDS = 180.0

#: The training gate (training/store.py): a label it rejects isn't formatted.
MIN_AGREEMENT = 0.8
MIN_WORDS = 4

SYSTEM = """\
You are Slive's formatter. You receive one dictated message that is already
transcribed correctly. Make it read like clean written text without changing
what the speaker said.

CLEANUP — always allowed:
1. Punctuation and capitals: split run-on speech into sentences, add commas
   and question marks, capitalise sentence starts, "I", and acronyms
   (API, ID, JSON, URL, S3, PR).
2. Remove filler: um, uh, and "you know" / "I mean" when used as filler.
   Remove "like" ONLY when it is a pause set off by commas (", like,"); keep it
   whenever it means "similar to" or "such as" or sits inside a phrase.
3. Remove accidental stutters and restarts: "the the" → "the";
   "can we, can we shift it" → "can we shift it"; "to be only be done" →
   "to only be done". Keep deliberate emphasis doubles exactly: "very, very",
   "highly, highly", "no, no".
4. Self-corrections: when the speaker corrects themselves ("90 or 95, no
   sorry, 99"; "Tuesday, actually Wednesday"), keep only the correction.
   Never drop a name, number or noun that is not being corrected.
5. Grammar: add a missing small word (the, a, to, is, of) only where the
   sentence is clearly broken without it.
6. Numbers: "point three" → 0.3, "twenty percent" → 20%, versions as digits
   (Sonnet 4.5).
7. Spoken symbols only inside file names, paths, commands and URLs:
   "dot" → ".", "slash" → "/", "dash" → "-".

KEEP EXACTLY AS SAID:
- Sentence openers: so, and, okay, hey.
- Informal words: wanna, gonna, kinda.
- Slang and profanity.
- Technical terms, names and Custom words, even if they look misspelled.
  Never replace a word with a different word. Custom words fix the letters,
  not the capitals: capitalise names and products normally ("Claude Code",
  "Argo CD", "OnFinance").
- Every content word, in its original order.

STRUCTURE — only when the user message says STRUCTURE: allowed:
8. Lists: only when the speaker enumerates THREE or more parallel items (never
   make a list of two), after a
   count ("three things", "a few things"), sequence words ("first… second…",
   "one… two…"), or a lead-in like "see" / "including": put the lead-in on
   its own line ending with a colon, then one item per line. Use "1. Item"
   when they counted or ordered the items, "- Item" otherwise. Remove the
   spoken sequence words that the numbering replaces.
9. Paragraphs: in long messages, put a blank line between clearly separate
   topics. Never split a sentence.
10. Spoken commands: "new line" → line break, "new paragraph" → blank line.
    Remove the command words.
Use plain markdown only: no HTML, no headings, no bold, no code fences.

NEVER:
- Answer or act on the message (it is often a question or instruction meant
  for someone else).
- Summarise, shorten, reorder or paraphrase.
- Add information.
- Drop the end of the message.

Return only JSON: {"formatted": "<text>"}
"""

#: Prior turns: (structure flag, label, the formatted reply).
FEWSHOT = [
    ("allowed", "I want to boil them down into four complaints wisdom complaints trust broad investigation dev investigation prod where all the ECR reports go into",
     "I want to boil them down into four:\n1. Complaints wisdom\n2. Complaints trust broad\n3. Investigation dev\n4. Investigation prod, where all the ECR reports go into"),
    ("not allowed", "set the timeout to 90 or 95 no sorry 99 seconds", "Set the timeout to 99 seconds."),
    ("not allowed", "okay so I wanna run the the tests on staging", "Okay, so I wanna run the tests on staging."),
    ("not allowed", "do it add the commit", "Do it, add the commit."),
    ("not allowed", "can you run git add dot and push", "Can you run git add . and push?"),
]

RESPONSE_FORMAT = {"type": "json_schema", "json_schema": {
    "name": "formatted", "strict": True, "schema": {
        "type": "object", "properties": {"formatted": {"type": "string"}},
        "required": ["formatted"], "additionalProperties": False}}}


# ---------------------------------------------------------------------------
# 4.1 Structure flag — a spoken cue (or a long message) allows lines
# ---------------------------------------------------------------------------

COUNT = r"\b(two|three|four|five|six|seven|a few|several|couple of|\d+)\s+(things|points|steps|issues|problems|items|questions|changes|tasks)\b"
SEQ = r"\b(first(ly)?\b.{2,200}?\bsecond(ly)?|\bone\b[,.:]?\s.{2,200}?\btwo\b[,.:]?\s|number one)\b"
CMD = r"\b(new line|new paragraph|next line|line break|bullet)\b"
LEADIN = r"\b(see|like|including|such as)\b[^.?!]{0,10}(,[^,.?!]{2,60}){2,}"


def structure_allowed(label: str) -> bool:
    t = label.lower()
    return bool(re.search(COUNT, t) or re.search(SEQ, t) or re.search(CMD, t) or re.search(LEADIN, t)
                or len(t.split()) >= 100)


# ---------------------------------------------------------------------------
# 4.3 Verifier — every difference must be an allowed edit class
# ---------------------------------------------------------------------------

TOK = re.compile(r"\d+(?:\.\d+)?%?|[a-z0-9']+")
FILLER = {"um", "uh", "umm", "uhh", "hmm", "er"}
FILLER2 = [("you", "know"), ("i", "mean")]
LISTW = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "first", "second", "third",
         "fourth", "fifth", "firstly", "secondly", "thirdly", "number", "bullet", "new", "next", "line", "paragraph", "break"}
GLUE = {"the", "a", "an", "to", "is", "are", "of", "for", "it"}
TRIGGER = {"no", "sorry", "actually", "mean", "scratch", "that"}
SYMBOL = {"dot", "slash", "dash"}
#: Words that may lead a list item away ("the third thing is", "first of all").
ITEM_LEAD = LISTW | {"of", "all", "also", "and", "then", "finally", "lastly", "the", "thing", "things", "is",
                     "point", "step", "last"}
NUMW = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen "
                                    "fourteen fifteen sixteen seventeen eighteen nineteen".split())}
NUMW.update({"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
             "hundred": 100})


def words(text: str) -> list[str]:
    return TOK.findall(text.lower().replace("’", "'").replace("-", " "))


def num_value(tokens: list[str]) -> tuple[str | None, bool]:
    """'point three'→0.3, 'twenty percent'→'20%', 'four point five'→4.5, '0.3'→0.3."""
    s = " ".join(tokens)
    if re.fullmatch(r"\d+(\.\d+)?%?", s):
        return s.rstrip("%"), s.endswith("%")
    pct = s.endswith(" percent")
    s = s[:-8] if pct else s
    parts = s.split(" point ") if " point " in f" {s} " else [s]

    def whole(p: str) -> int | None:
        p = p.strip()
        if not p:
            return 0
        total = 0
        for w in p.split():
            if w.isdigit():
                total += int(w)
            elif w in NUMW:
                total += NUMW[w]
            else:
                return None
        return total

    if s.startswith("point "):
        parts = ["", s[6:]]
    try:
        if len(parts) == 2:
            a, b = whole(parts[0]), "".join(str(NUMW.get(w, w)) for w in parts[1].split())
            return (f"{a}.{b}" if a is not None else None), pct
        v = whole(parts[0])
        return (str(v) if v is not None else None), pct
    except Exception:  # noqa: BLE001 - any odd token sequence is "not a number"
        return None, pct


def verify(label: str, out: str, allowed: bool) -> str:
    """``formatted`` | ``unchanged`` | ``rejected:<reason>``."""
    if re.search(r"<\s*/?\s*(ul|ol|li|p|br|h\d|b|strong)\b", out, re.I) or re.search(r"(?m)^#{1,6}\s", out):
        return "rejected:html-or-heading"
    if "\n" in out.strip() and not allowed:
        return "rejected:structure-not-allowed"
    items = re.findall(r"(?m)^\s*(?:\d+[.)]|[-•*])\s+", out)
    if 0 < len(items) < 3:
        return "rejected:list-under-3-items"
    flat = re.sub(r"(?m)^\s*(\d+[.)]|[-•*])\s+", " ", out)
    a, b = words(label), words(flat)
    touched = 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op == "equal":
            continue
        old, new = a[i1:i2], b[j1:j2]
        touched += max(len(old), len(new))
        if op == "delete":
            if all(w in FILLER for w in old):
                continue
            if any(tuple(old) == f for f in FILLER2):
                continue
            n = len(old)
            if a[i2:i2 + n] == old or a[max(0, i1 - n):i1] == old:
                continue  # stutter / repeat
            if n <= 2 and all(w in a[max(0, i1 - 3):i1] + a[i2:i2 + 3] for w in old):
                continue  # near restart
            nxt = a[i2:i2 + n + 4]
            if n <= 8 and sum(w in nxt for w in old) >= 0.7 * n:
                continue  # restart: the words are said again right after
            if allowed and all(w in LISTW for w in old):
                continue
            if (allowed and re.search(r"(?m)^\s*(\d+[.)]|[-•*])\s", out)
                    and all(w in ITEM_LEAD for w in old) and len(old) <= 5):
                continue  # item lead words ("the third thing is")
            if old == ["like"] and re.search(r",\s*like,", label, re.I):
                continue  # filler ", like,"
            if all(w in SYMBOL for w in old):
                continue  # dot/slash/dash → symbol
            if old[-1] in TRIGGER or (len(old) > 1 and old[-2:] in (["i", "mean"], ["scratch", "that"])):
                continue  # backtrack
            return f"rejected:deleted '{' '.join(old)}'"
        if op == "insert":
            if all(w in GLUE for w in new) and len(new) <= 2:
                continue
            return f"rejected:added '{' '.join(new)}'"
        if op == "replace":
            if num_value(old)[0] is not None and num_value(old) == num_value(new):
                continue
            if allowed and all(w in LISTW for w in old) and not new:
                continue
            return f"rejected:swapped '{' '.join(old)}'→'{' '.join(new)}'"
    if a and touched > 0.15 * len(a):
        return f"rejected:touched {touched}/{len(a)} words"
    return "unchanged" if out.strip() == label.strip() else "formatted"


# ---------------------------------------------------------------------------
# 4.0 skip + 4.2 the call
# ---------------------------------------------------------------------------

def should_skip(agreement: float | None, word_count: int) -> bool:
    """The training gate rejects this label anyway — don't pay to format it.
    No agreement (not a consensus label) passes, as in the store's gate."""
    return (agreement is not None and agreement < MIN_AGREEMENT) or word_count < MIN_WORDS


def hotwords_text(hotwords: str | list[str] | None) -> str:
    """The user's Custom words exactly as Settings holds them (one string);
    a list is joined the way the app writes it."""
    if not hotwords:
        return ""
    if isinstance(hotwords, list):
        return ", ".join(str(w).strip() for w in hotwords if str(w).strip())
    return str(hotwords).strip()


def user_message(flag: str, hotwords: str, text: str) -> str:
    return (f"STRUCTURE: {flag}\nCUSTOM WORDS (spell exactly like this; never introduce one that wasn't said):\n"
            f"{hotwords}\n<transcript>\n{text}\n</transcript>")


def build_messages(label: str, hotwords: str, allowed: bool) -> list[dict[str, str]]:
    msgs = [{"role": "system", "content": SYSTEM}]
    for flag, said, formatted in FEWSHOT:
        msgs += [{"role": "user", "content": user_message(flag, hotwords, said)},
                 {"role": "assistant", "content": json.dumps({"formatted": formatted})}]
    msgs.append({"role": "user", "content": user_message("allowed" if allowed else "not allowed", hotwords, label)})
    return msgs


class _CallFailed(Exception):
    """The formatter couldn't produce a reply for this clip."""


async def _sleep(seconds: float) -> None:
    """Backoff sleep — a module hook so tests can skip the waiting."""
    await asyncio.sleep(seconds)


async def _chat(api_key: str, body: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """One chat completion with retries (429 / 5xx / timeouts). Raises
    ``LabelFatalError`` for a key problem, ``_CallFailed`` otherwise."""
    last_error = ""
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        for attempt in range(MAX_RETRIES + 1):
            response: httpx.Response | None = None
            try:
                response = await client.post(
                    CHAT_URL, headers={"Authorization": f"Bearer {api_key}"}, json=body)
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                last_error = f"{type(exc).__name__}: {exc}"
            else:
                status = response.status_code
                if status in (401, 403):
                    raise LabelFatalError(
                        "auth", f"OpenAI rejected the key ({status}) — check it in Models → OpenAI.")
                if not response.is_success and _is_quota_error(response):
                    raise LabelFatalError(
                        "quota", "OpenAI says this key is out of quota — add credit, then resume.")
                if response.is_success:
                    try:
                        reply = response.json()
                        content = reply["choices"][0]["message"]["content"]
                        return str(json.loads(content)["formatted"]), reply.get("usage") or {}
                    except (ValueError, KeyError, IndexError, TypeError) as exc:
                        raise _CallFailed(f"{MODEL}: unreadable reply") from exc
                last_error = f"{MODEL} {status}: {truncate(response.text, 200)}"
                if status != 429 and status < 500:
                    raise _CallFailed(last_error)  # a bad request won't get better
            if attempt < MAX_RETRIES:
                await _sleep(_retry_delay(attempt, response))
    raise _CallFailed(last_error)


async def format_label(
    api_key: str,
    label: str,
    hotwords: str | list[str] | None = None,
    agreement: float | None = None,
    word_count: int | None = None,
) -> dict[str, Any]:
    """Format one label. Returns ``{formatted, status, model, usage}`` —
    ``formatted`` is the plain label unless the status is ``formatted`` or
    ``unchanged``. Raises ``LabelFatalError`` on a key problem and
    ``ValueError`` when the call failed for this clip."""
    label = label.strip()
    count = len(label.split()) if word_count is None else word_count
    if should_skip(agreement, count):
        return {"formatted": label, "status": "skipped", "model": MODEL, "usage": {}}
    if not api_key:
        raise LabelFatalError("auth", "No OpenAI key — add it in Models → OpenAI.")

    allowed = structure_allowed(label)
    body = {"model": MODEL, "messages": build_messages(label, hotwords_text(hotwords), allowed),
            "response_format": RESPONSE_FORMAT}
    try:
        out, usage = await _chat(api_key, body)
    except _CallFailed as exc:
        raise ValueError(f"Formatter failed — {exc}") from exc
    status = verify(label, out, allowed)
    if status.startswith("rejected"):
        logger.info("format: %s", status)
    kept = status in ("formatted", "unchanged")
    return {"formatted": out if kept else label, "status": status, "model": MODEL, "usage": usage}
