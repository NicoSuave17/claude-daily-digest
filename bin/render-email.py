#!/usr/bin/env python3
"""
Render the daily digest JSON into a multipart MIME email (.eml).

Shape-aware: each output_shape gets a distinct visual treatment appropriate
to its editorial intent. All shapes share Anthropic's cream palette and
serif/sans mix.

Input:
  digest.json — produced by `claude -p` per the schema in templates/prompt.tpl.

Output:
  <out.eml> — valid RFC 5322 multipart/alternative email (HTML + plain text).

Usage:
  render-email.py <digest.json> <out.eml>
"""

import json
import sys
import os
import html
import textwrap
from datetime import datetime
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# ------------------------------ Palette ------------------------------ #
# Anthropic-derived cream palette. Hex codes observed from their stylesheets.
BG_PAGE = "#faf9f5"
BG_PANEL = "#f4f4eb"
BG_WARM = "#fcf6f0"
BG_ALARM = "#fbeee6"
TEXT_PRIMARY = "#141413"
TEXT_MUTED = "#6b6b66"
TEXT_DIM = "#a8a69b"
BORDER = "#e8e6d9"
ACCENT_CLAY = "#cc785c"
ACCENT_BURNT = "#f35c07"
ACCENT_GREEN = "#2c5f41"
ACCENT_RUST = "#a35a3c"

SERIF = "Charter,'Iowan Old Style',Georgia,'Times New Roman',serif"
SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,'SF Mono',Menlo,Consolas,monospace"


# ------------------------------ Helpers ------------------------------ #
def esc(s):
    if s is None:
        return ""
    return html.escape(str(s), quote=True)


def kicker_style(kicker):
    """Dynamic kickers get dynamic colors. Map common ones; fall back to neutral."""
    if not kicker:
        return ACCENT_CLAY
    k = kicker.upper()
    if "PARADIGM" in k or "SECURITY" in k or "ALARM" in k:
        return ACCENT_BURNT
    if "SKIP" in k or "ALREADY" in k:
        return TEXT_MUTED
    if "VERIFY" in k or "CAUTION" in k:
        return ACCENT_RUST
    if "ADJACENT" in k or "DISCOVER" in k:
        return ACCENT_GREEN
    return ACCENT_CLAY


def changes_html(bullets):
    if not bullets:
        return ""
    rows = []
    for raw in bullets:
        line = str(raw).strip()
        if line.startswith("+"):
            color, marker, text = ACCENT_GREEN, "+", line.lstrip("+ ").strip()
        elif line.startswith("-") or line.startswith("\u2013") or line.startswith("\u2014"):
            color, marker, text = ACCENT_RUST, "\u2013", line.lstrip("-\u2013\u2014 ").strip()
        else:
            color, marker, text = TEXT_PRIMARY, "\u00b7", line.lstrip("\u00b7 ").strip()
        rows.append(
            f'<tr><td style="padding:4px 0;vertical-align:top;width:18px;color:{color};font-weight:700;font-family:{SANS};font-size:15px;line-height:1.55;">{marker}</td>'
            f'<td style="padding:4px 0;font-family:{SANS};font-size:15px;line-height:1.6;color:{TEXT_PRIMARY};">{esc(text)}</td></tr>'
        )
    return (
        f'<table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin:4px 0;">'
        + "".join(rows)
        + "</table>"
    )


def decision_block_html(d, index, total, amplified=False):
    """One decision, rendered as a card. `amplified` for the single most important
    decision in an alarm or when kicker signals urgency."""
    kicker = d.get("kicker", "").upper()
    kick_color = kicker_style(kicker)

    title_size = 26 if amplified else 22
    bar_width = 4 if amplified else 2
    bar_color = kick_color if amplified else ACCENT_CLAY

    counter_line = (
        f'<span style="color:{TEXT_DIM};">{index} of {total}</span>'
        f'&nbsp;&nbsp;·&nbsp;&nbsp;'
        f'<span style="color:{kick_color};">{esc(kicker) or "NOTE"}</span>'
        f'&nbsp;&nbsp;·&nbsp;&nbsp;'
        f'<span style="color:{TEXT_MUTED};">{esc(d.get("version_tag",""))}</span>'
    )

    recommendation = esc(d.get("recommendation", ""))

    return f"""
<tr><td style="padding:36px 40px 0 40px;">
  <div style="border-left:{bar_width}px solid {bar_color}; padding-left:20px;">
    <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;margin-bottom:10px;">
      {counter_line}
    </div>
    <h3 style="margin:0 0 18px 0;font-family:{SERIF};font-weight:500;font-size:{title_size}px;line-height:1.22;letter-spacing:-0.005em;color:{TEXT_PRIMARY};">
      {esc(d.get('title',''))}
    </h3>

    <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:{TEXT_MUTED};margin:18px 0 6px 0;">What it is</div>
    <p style="margin:0;font-family:{SERIF};font-size:16px;line-height:1.7;color:{TEXT_PRIMARY};">
      {esc(d.get('what_it_is',''))}
    </p>

    <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:{TEXT_MUTED};margin:22px 0 6px 0;">What you do now</div>
    <p style="margin:0;font-family:{SERIF};font-size:16px;line-height:1.7;color:{TEXT_PRIMARY};">
      {esc(d.get('what_you_do_now',''))}
    </p>

    {('<div style="font-family:' + SANS + ';font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:' + TEXT_MUTED + ';margin:22px 0 2px 0;">What would change</div>' + changes_html(d.get('what_would_change') or [])) if (d.get('what_would_change') or []) else ''}

    <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background:{BG_WARM};border-left:3px solid {kick_color};margin:22px 0 0 0;">
      <tr><td style="padding:20px 24px;">
        <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:{kick_color};margin-bottom:8px;">
          {esc(kicker) or 'Recommendation'}
        </div>
        <p style="margin:0;font-family:{SERIF};font-size:16px;line-height:1.6;color:{TEXT_PRIMARY};">
          {recommendation}
        </p>
      </td></tr>
    </table>
  </div>
</td></tr>
"""


def also_shipped_html(items):
    if not items:
        return ""
    rows = "".join(
        f'<p style="margin:8px 0;font-family:{SANS};font-size:14px;line-height:1.6;color:{TEXT_PRIMARY};">'
        f'<span style="color:{TEXT_DIM};">·</span>&nbsp;&nbsp;{esc(item)}</p>'
        for item in items
    )
    return f"""
<tr><td style="padding:48px 40px 0 40px;">
  <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:{TEXT_MUTED};margin-bottom:14px;">
    Also shipped — worth knowing
  </div>
  {rows}
</td></tr>
"""


def couldnt_verify_html(items):
    if not items:
        return ""
    rows = "".join(
        f'<p style="margin:8px 0;font-family:{SANS};font-size:14px;line-height:1.6;color:{TEXT_MUTED};">'
        f'<span style="color:{TEXT_DIM};">·</span>&nbsp;&nbsp;{esc(item)}</p>'
        for item in items
    )
    return f"""
<tr><td style="padding:40px 40px 0 40px;">
  <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:{TEXT_MUTED};margin-bottom:12px;">
    What I couldn't verify
  </div>
  {rows}
</td></tr>
"""


def version_status_html(d, compact=False):
    """Compact for alarm/quiet; full for digest/retrospective."""
    if compact:
        return f"""
<tr><td style="padding:8px 40px 0 40px;">
  <p style="margin:0;font-family:{SANS};font-size:13px;color:{TEXT_MUTED};line-height:1.6;">
    <span style="color:{TEXT_PRIMARY};font-variant-numeric:tabular-nums;">{esc(d.get('version_before',''))}</span>
    &nbsp;→&nbsp;
    <span style="color:{TEXT_PRIMARY};font-variant-numeric:tabular-nums;">{esc(d.get('version_after',''))}</span>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    Upstream <span style="color:{TEXT_PRIMARY};font-variant-numeric:tabular-nums;">{esc(d.get('version_upstream',''))}</span>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    {esc(d.get('update_action',''))}
  </p>
</td></tr>
"""
    return f"""
<tr><td style="padding:8px 40px 24px 40px;">
  <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:{TEXT_MUTED};margin-bottom:12px;">Version status</div>
  <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="font-family:{SANS};font-size:15px;color:{TEXT_PRIMARY};">
    <tr><td style="padding:4px 0;color:{TEXT_MUTED};width:42%;">Installed (before)</td><td style="padding:4px 0;font-variant-numeric:tabular-nums;">{esc(d.get('version_before',''))}</td></tr>
    <tr><td style="padding:4px 0;color:{TEXT_MUTED};">Installed (after)</td><td style="padding:4px 0;font-variant-numeric:tabular-nums;">{esc(d.get('version_after',''))}</td></tr>
    <tr><td style="padding:4px 0;color:{TEXT_MUTED};">Upstream latest</td><td style="padding:4px 0;font-variant-numeric:tabular-nums;">{esc(d.get('version_upstream',''))}</td></tr>
    <tr><td style="padding:4px 0;color:{TEXT_MUTED};">Update action</td><td style="padding:4px 0;">{esc(d.get('update_action',''))}</td></tr>
  </table>
</td></tr>
"""


def header_block_html(d, shape):
    """Top of email: kicker + headline + subheadline. Shape-tuned."""
    kicker_label = {
        "alarm": "Claude Code Digest · Alarm",
        "essay": "Claude Code Digest · Essay",
        "digest": "Claude Code Digest",
        "quiet": "Claude Code Digest · Quiet Day",
        "callback": "Claude Code Digest · Callback",
        "retrospective": "Claude Code Digest · Retrospective",
    }.get(shape, "Claude Code Digest")
    kicker_color = {
        "alarm": ACCENT_BURNT,
        "essay": ACCENT_CLAY,
        "digest": TEXT_MUTED,
        "quiet": TEXT_MUTED,
        "callback": ACCENT_CLAY,
        "retrospective": ACCENT_CLAY,
    }.get(shape, TEXT_MUTED)

    headline_size = 38 if shape == "alarm" else 34

    return f"""
<tr><td style="padding:48px 40px 24px 40px;">
  <div style="font-family:{SANS};font-size:12px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:{kicker_color};margin-bottom:14px;">
    {kicker_label} &nbsp;·&nbsp; {esc(d.get('date_long',''))}
  </div>
  <h1 style="margin:0 0 10px 0;font-family:{SERIF};font-weight:500;font-size:{headline_size}px;line-height:1.12;letter-spacing:-0.012em;color:{TEXT_PRIMARY};">
    {esc(d.get('headline',''))}
  </h1>
  <p style="margin:0;font-family:{SANS};font-size:14px;color:{TEXT_MUTED};">
    {esc(d.get('subheadline',''))}
  </p>
</td></tr>
"""


def tldr_block_html(d):
    tldr = d.get("tldr")
    if not tldr:
        return ""
    return f"""
<tr><td style="padding:8px 40px 24px 40px;">
  <p style="margin:0;font-family:{SERIF};font-size:19px;line-height:1.55;color:#3c3c3c;">
    {esc(tldr)}
  </p>
</td></tr>
"""


def divider_html(pad_y=16):
    return f"""
<tr><td style="padding:{pad_y}px 40px;">
  <div style="border-top:1px solid {BORDER};height:1px;line-height:1px;font-size:1px;">&nbsp;</div>
</td></tr>
"""


def footer_html(d):
    digest_path = d.get("digest_md_path", "")
    filename = os.path.basename(digest_path) if digest_path else ""
    sent_at = datetime.now().strftime("%-I:%M %p %Z")
    return f"""
<tr><td style="padding:20px 40px 48px 40px;">
  <p style="margin:0 0 4px 0;font-family:{SANS};font-size:13px;color:{TEXT_MUTED};">
    Sent by your local daemon at {sent_at}.
  </p>
  <p style="margin:0;font-family:{SANS};font-size:13px;color:{TEXT_MUTED};">
    Full digest: <a href="file://{esc(digest_path)}" style="color:{ACCENT_CLAY};text-decoration:none;">{esc(filename)}</a> &nbsp;·&nbsp; <a href="https://code.claude.com/docs/en/changelog" style="color:{ACCENT_CLAY};text-decoration:none;">Upstream changelog</a>
  </p>
</td></tr>
"""


def essay_body_html(body):
    """Long-form prose. Split on blank lines into paragraphs."""
    paragraphs = [p.strip() for p in (body or "").split("\n\n") if p.strip()]
    rendered = "".join(
        f'<p style="margin:0 0 18px 0;font-family:{SERIF};font-size:17px;line-height:1.75;color:{TEXT_PRIMARY};">{esc(p)}</p>'
        for p in paragraphs
    )
    return f"""
<tr><td style="padding:16px 40px 24px 40px;">
  {rendered}
</td></tr>
"""


# ------------------------------ Shape dispatch ------------------------------ #
def render_alarm(d):
    decisions = d.get("decisions", []) or []
    total = len(decisions)
    decisions_html = "".join(
        decision_block_html(item, i + 1, total, amplified=(i == 0))
        for i, item in enumerate(decisions)
    )
    return (
        header_block_html(d, "alarm")
        + tldr_block_html(d)
        + version_status_html(d, compact=True)
        + divider_html()
        + decisions_html
        + (also_shipped_html(d.get("also_shipped") or []))
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


def render_essay(d):
    decisions = d.get("decisions", []) or []
    total = len(decisions)
    decisions_html = "".join(
        decision_block_html(item, i + 1, total) for i, item in enumerate(decisions)
    )
    return (
        header_block_html(d, "essay")
        + tldr_block_html(d)
        + version_status_html(d, compact=True)
        + divider_html()
        + essay_body_html(d.get("essay_body") or "")
        + (divider_html() + decisions_html if decisions_html else "")
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


def render_digest(d):
    decisions = d.get("decisions", []) or []
    total = len(decisions)
    decisions_html = "".join(
        decision_block_html(item, i + 1, total) for i, item in enumerate(decisions)
    )
    return (
        header_block_html(d, "digest")
        + tldr_block_html(d)
        + version_status_html(d, compact=False)
        + divider_html()
        + decisions_html
        + also_shipped_html(d.get("also_shipped") or [])
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


def render_quiet(d):
    return (
        header_block_html(d, "quiet")
        + tldr_block_html(d)
        + version_status_html(d, compact=True)
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


def render_callback(d):
    decisions = d.get("decisions", []) or []
    total = len(decisions)
    decisions_html = "".join(
        decision_block_html(item, i + 1, total) for i, item in enumerate(decisions)
    )
    callback_ref = d.get("callback_to", "")
    callback_block = (
        f"""
<tr><td style="padding:8px 40px 24px 40px;">
  <div style="font-family:{SANS};font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:{TEXT_MUTED};margin-bottom:10px;">Coming back to</div>
  <p style="margin:0;font-family:{SERIF};font-size:17px;line-height:1.6;color:#3c3c3c;">{esc(callback_ref)}</p>
</td></tr>
"""
        if callback_ref
        else ""
    )
    return (
        header_block_html(d, "callback")
        + tldr_block_html(d)
        + callback_block
        + version_status_html(d, compact=True)
        + divider_html()
        + decisions_html
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


def render_retrospective(d):
    decisions = d.get("decisions", []) or []
    total = len(decisions)
    decisions_html = "".join(
        decision_block_html(item, i + 1, total) for i, item in enumerate(decisions)
    )
    return (
        header_block_html(d, "retrospective")
        + tldr_block_html(d)
        + version_status_html(d, compact=False)
        + divider_html()
        + decisions_html
        + also_shipped_html(d.get("also_shipped") or [])
        + couldnt_verify_html(d.get("couldnt_verify") or [])
        + divider_html(pad_y=32)
        + footer_html(d)
    )


SHAPE_RENDERERS = {
    "alarm": render_alarm,
    "essay": render_essay,
    "digest": render_digest,
    "quiet": render_quiet,
    "callback": render_callback,
    "retrospective": render_retrospective,
}


# ------------------------------ Plain text ------------------------------ #
def plain_text(d):
    out = []
    out.append("CLAUDE CODE DIGEST — " + (d.get("date_long") or ""))
    out.append("")
    if d.get("headline"):
        out.append(d["headline"])
    if d.get("subheadline"):
        out.append(d["subheadline"])
    out.append("")
    out.append("-" * 60)
    out.append("")
    if d.get("tldr"):
        out.append("TL;DR")
        out.append("")
        out.append(textwrap.fill(d["tldr"], width=72))
        out.append("")
        out.append("-" * 60)
        out.append("")
    out.append("VERSION STATUS")
    out.append(f"  Installed before   {d.get('version_before','')}")
    out.append(f"  Installed after    {d.get('version_after','')}")
    out.append(f"  Upstream latest    {d.get('version_upstream','')}")
    out.append(f"  Update action      {d.get('update_action','')}")
    out.append("")

    if d.get("essay_body"):
        out.append("-" * 60)
        out.append("")
        for para in d["essay_body"].split("\n\n"):
            out.append(textwrap.fill(para.strip(), width=72))
            out.append("")

    decisions = d.get("decisions") or []
    if decisions:
        out.append("-" * 60)
        out.append("")
        out.append("DECISIONS")
        out.append("")
        total = len(decisions)
        for i, item in enumerate(decisions, 1):
            out.append(f"{i} of {total}  ·  {item.get('kicker','').upper()}  ·  {item.get('version_tag','')}")
            out.append("")
            out.append(item.get("title", ""))
            out.append("")
            out.append("  WHAT IT IS")
            out.append(textwrap.fill(item.get("what_it_is", ""), width=72, initial_indent="  ", subsequent_indent="  "))
            out.append("")
            out.append("  WHAT YOU DO NOW")
            out.append(textwrap.fill(item.get("what_you_do_now", ""), width=72, initial_indent="  ", subsequent_indent="  "))
            out.append("")
            changes = item.get("what_would_change") or []
            if changes:
                out.append("  WHAT WOULD CHANGE")
                for c in changes:
                    out.append("    " + str(c))
                out.append("")
            out.append("  " + item.get("kicker", "RECOMMENDATION").upper())
            out.append(textwrap.fill(item.get("recommendation", ""), width=72, initial_indent="  ", subsequent_indent="  "))
            out.append("")
            out.append("")

    also = d.get("also_shipped") or []
    if also:
        out.append("-" * 60)
        out.append("")
        out.append("ALSO SHIPPED")
        out.append("")
        for a in also:
            out.append("  · " + str(a))
        out.append("")

    cv = d.get("couldnt_verify") or []
    if cv:
        out.append("-" * 60)
        out.append("")
        out.append("WHAT I COULDN'T VERIFY")
        out.append("")
        for c in cv:
            out.append("  · " + str(c))
        out.append("")

    out.append("-" * 60)
    out.append("")
    out.append(f"Full digest: {d.get('digest_md_path','')}")
    out.append("Upstream changelog: https://code.claude.com/docs/en/changelog")
    return "\n".join(out)


# ------------------------------ Build ------------------------------ #
def build(digest_path, out_path):
    with open(digest_path, "r", encoding="utf-8") as f:
        d = json.load(f)

    shape = d.get("output_shape") or "digest"
    if shape not in SHAPE_RENDERERS:
        shape = "digest"

    inner_html = SHAPE_RENDERERS[shape](d)

    full_html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(d.get('subject','Claude Code Digest'))}</title>
</head>
<body style="margin:0;padding:0;background:{BG_PAGE};font-family:{SERIF};color:{TEXT_PRIMARY};-webkit-font-smoothing:antialiased;">
<center style="width:100%;background:{BG_PAGE};">
<table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="max-width:640px;margin:0 auto;background:{BG_PAGE};">
  {inner_html}
</table>
</center>
</body>
</html>
"""

    text_body = plain_text(d)

    msg = EmailMessage()
    msg["Subject"] = d.get("subject", "Claude Code Digest")
    msg["From"] = d.get("from", "")
    msg["To"] = d.get("to", "")
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="claude-daily-digest.local")

    msg.set_content(text_body)
    msg.add_alternative(full_html, subtype="html")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(msg.as_string())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <digest.json> <out.eml>", file=sys.stderr)
        sys.exit(2)
    build(sys.argv[1], sys.argv[2])
