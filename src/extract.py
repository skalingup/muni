#!/usr/bin/env python3
"""Extract a PDF into clean, reflowable reader JSON.
Usage: extract.py <input.pdf> <output.json>
Requires PyMuPDF (fitz). Uses the PDF outline for chapters when present,
decodes private-use ligature glyphs, and safely repairs dropped fi/fl/ff/ft
ligatures using the system word list (collision-checked, never corrupts real words)."""
import sys, json, re, os, base64, io

try:
    from PIL import Image
    _HAVE_PIL = True
except Exception:
    _HAVE_PIL = False

IMG_BUDGET = [8 * 1024 * 1024]   # total embedded image bytes per book (reset per run)

def _encode_image(raw, ext):
    """Downscale/re-encode large images so the JSON stays reasonable."""
    if _HAVE_PIL:
        try:
            im = Image.open(io.BytesIO(raw)); w, h = im.size
            scale = min(1.0, 1100.0 / max(w, h))
            if scale < 1.0 or len(raw) > 400_000:
                if scale < 1.0:
                    im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
                if im.mode in ("RGBA", "P", "LA"):
                    im = im.convert("RGB")
                buf = io.BytesIO(); im.save(buf, format="JPEG", quality=80)
                return buf.getvalue(), "jpeg"
        except Exception:
            pass
    return raw, ext

try:
    import fitz
except Exception as e:
    json.dump({"error": "PyMuPDF (fitz) not available: %s" % e},
              open(sys.argv[2], "w"))
    sys.exit(0)

# --- Glyph decode: private-use + standard ligatures -> real text ----------
LIG = {
    chr(0xE062): "Th", chr(0xE0BB): "Th",
    chr(0xE09D): "ft", chr(0xE117): "ft",
    chr(0x16): "fi", chr(0x19): "fl",          # some fonts encode ligatures as control chars
    "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl",
    "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "ft", "ﬆ": "st",
    " ": " ", "�": "",
}

# Any leftover control / zero-width / invisible chars that would render as tofu boxes.
INVIS = re.compile("[" + "\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f" +
                   chr(0x00AD)+chr(0x200B)+chr(0x200C)+chr(0x200D)+chr(0xFEFF)+chr(0x2060)+chr(0xFFFD) + "]")

# --- Safe dropped-ligature repair (dictionary-checked) --------------------
WORDS = set()
try:
    for _l in open("/usr/share/dict/words"):
        _l = _l.strip().lower()
        if _l:
            WORDS.add(_l)
except Exception:
    pass

LIGS = ["ffi", "ffl", "fi", "fl", "ff", "ft"]
BLOCK = {"ve", "ll", "re", "st", "nd", "rd", "th", "s", "t", "d", "m", "ed", "es"}

def _is_real(tl):
    if tl in WORDS:
        return True
    c = []
    if tl.endswith("s"):   c.append(tl[:-1])
    if tl.endswith("es"):  c.append(tl[:-2])
    if tl.endswith("d"):   c.append(tl[:-1])
    if tl.endswith("ed"):  c += [tl[:-2], tl[:-1]]
    if tl.endswith("ing"): c += [tl[:-3], tl[:-3] + "e"]
    if tl.endswith("er"):  c += [tl[:-2], tl[:-1]]
    if tl.endswith("ier"): c.append(tl[:-3] + "y")
    if tl.endswith("ies"): c.append(tl[:-3] + "y")
    if tl.endswith("ly"):  c.append(tl[:-2])
    if tl.endswith("est"): c += [tl[:-3], tl[:-3] + "y"]
    return any(x in WORDS for x in c)

def _repair_token(t):
    if len(t) < 2 or not WORDS:
        return t
    tl = t.lower()
    if tl in BLOCK or _is_real(tl):
        return t
    found = set()
    for i in range(len(tl) + 1):
        for lg in LIGS:
            cand = tl[:i] + lg + tl[i:]
            if cand in WORDS:
                found.add(cand)
    if len(found) == 1:
        rep = found.pop()
        if t.isupper():
            return rep.upper()
        if t[0].isupper():
            return rep.capitalize()
        return rep
    return t

_TOK = re.compile(r"[A-Za-z][A-Za-z']*")
def _repair_text(s):
    return _TOK.sub(lambda m: _repair_token(m.group(0)), s)

def _dehyph(m):
    a, b = m.group(1), m.group(2)
    if (a + b).lower() in WORDS:            # word merely wrapped: rejoin
        return a + b
    if a.lower() in WORDS and b.lower() in WORDS:   # genuine compound: keep hyphen
        return a + "-" + b
    return a + b

def clean(s, repair=True):
    if not s:
        return ""
    for k, v in LIG.items():
        s = s.replace(k, v)
    s = re.sub(r"([A-Za-z]+)-\n([A-Za-z]+)", _dehyph, s)   # smart de-hyphenate across line breaks
    s = s.replace("\n", " ")
    s = INVIS.sub("", s)                       # drop any remaining tofu-causing chars
    s = re.sub(r"[ \t]+", " ", s).strip()
    if repair:
        s = _repair_text(s)
    return s

def is_heading(s):
    if not s or len(s) > 70:
        return False
    if s[-1] in ".,:;?!—-":
        return False
    letters = [c for c in s if c.isalpha()]
    if not letters:
        return False
    return sum(c.isupper() for c in letters) / len(letters) > 0.7

def page_blocks(d, a, b):
    out = []
    for pno in range(a, min(b, d.page_count)):
        page = d[pno]
        items = []   # (y, block) so text + images interleave in reading order
        for blk in page.get_text("blocks"):
            c = clean(blk[4])           # image blocks have empty text -> naturally skipped
            if c:
                items.append((blk[1], {"t": "h" if is_heading(c) else "p", "s": c, "p": pno + 1}))
        try:
            for blk in page.get_text("dict").get("blocks", []):
                if blk.get("type") != 1:
                    continue
                w, h = blk.get("width", 0), blk.get("height", 0)
                raw = blk.get("image")
                if not raw or w < 48 or h < 48 or IMG_BUDGET[0] <= 0:
                    continue            # skip tiny/decorative glyphs, logos, bullets
                enc, ext = _encode_image(raw, blk.get("ext", "png"))
                if len(enc) > IMG_BUDGET[0]:
                    continue
                IMG_BUDGET[0] -= len(enc)
                src = "data:image/%s;base64,%s" % (ext, base64.b64encode(enc).decode("ascii"))
                items.append((blk["bbox"][1], {"t": "img", "src": src, "p": pno + 1}))
        except Exception:
            pass
        items.sort(key=lambda x: x[0])
        out.extend(it[1] for it in items)
    return out

def main():
    pdf, out = sys.argv[1], sys.argv[2]
    try:
        d = fitz.open(pdf)
    except Exception as e:
        json.dump({"error": "Could not open this PDF (it may have been moved or deleted)."},
                  open(out, "w"), ensure_ascii=False)
        return
    title = (d.metadata or {}).get("title") or os.path.splitext(os.path.basename(pdf))[0]
    title = clean(title, repair=False) or "Untitled"
    IMG_BUDGET[0] = 8 * 1024 * 1024

    # Scanned / image-only detection: almost no extractable text.
    raw_chars = sum(len(d[i].get_text("text")) for i in range(min(d.page_count, 30)))
    sampled = min(d.page_count, 30)
    if sampled and raw_chars / sampled < 40:
        json.dump({"title": title, "scanned": True, "pages": d.page_count},
                  open(out, "w"), ensure_ascii=False)
        return

    toc = d.get_toc()
    chapters = []
    if toc and len(toc) >= 2:
        for i, (lvl, t, page) in enumerate(toc):
            start = max(0, page - 1)
            end = (toc[i + 1][2] - 1) if i + 1 < len(toc) else d.page_count
            ct = clean(t, repair=False) or "Section"
            blocks = page_blocks(d, start, max(start + 1, end))
            if blocks and blocks[0]["s"].strip().lower() == ct.strip().lower():
                blocks = blocks[1:]
            chapters.append({"title": ct, "level": lvl, "blocks": blocks})
    else:
        # No outline: synthesize chapters from detected headings; fall back to page groups.
        all_blocks = page_blocks(d, 0, d.page_count)
        heads = [i for i, bl in enumerate(all_blocks)
                 if bl["t"] == "h" and 3 <= len(bl["s"]) <= 60]
        # require headings to be reasonably spaced to act as chapter starts
        if len(heads) >= 3 and len(heads) <= max(4, len(all_blocks) // 8):
            starts = heads if heads[0] == 0 else [0] + heads
            for j, st in enumerate(starts):
                en = starts[j + 1] if j + 1 < len(starts) else len(all_blocks)
                seg = all_blocks[st:en]
                ct = seg[0]["s"] if seg and seg[0]["t"] == "h" else "Section %d" % (j + 1)
                body = seg[1:] if (seg and seg[0]["t"] == "h") else seg
                chapters.append({"title": ct[:70], "level": 1, "blocks": body})
        else:
            # group pages into ~12-page chapters for a usable contents list
            step = 12 if d.page_count > 24 else d.page_count
            for a in range(0, d.page_count, step):
                b = min(a + step, d.page_count)
                lbl = "Pages %d–%d" % (a + 1, b) if step < d.page_count else title
                chapters.append({"title": lbl, "level": 1, "blocks": page_blocks(d, a, b)})

    if not chapters:
        chapters = [{"title": title, "level": 1, "blocks": []}]

    json.dump({"title": title, "pages": d.page_count, "chapters": chapters},
              open(out, "w"), ensure_ascii=False)

if __name__ == "__main__":
    main()
