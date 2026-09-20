/**
 * Markdown → HTML for the policy pages.
 *
 * Hand-written rather than pulled from a dependency, because the input is not
 * arbitrary markdown: it is two staff-authored documents in `policy_documents`
 * using headings, paragraphs, unordered lists, bold, italic and links. A
 * general parser would be more supply chain and no more correct for this.
 *
 * Every line is HTML-escaped before any tag is emitted, so a stray `<script>`
 * in the policy text renders as visible text. The table is writable only by
 * service_role, so this is defence in depth rather than the primary control —
 * but it is the difference between a bad paste and stored XSS on the public
 * site, and the output is injected with dangerouslySetInnerHTML.
 */

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Inline spans, applied to already-escaped text. */
function inline(text: string): string {
  return text
    // Only http(s) and mailto targets, so no javascript: URL can be authored.
    .replace(
      /\[([^\]]+)\]\(((?:https?:\/\/|mailto:)[^\s)]+)\)/g,
      '<a href="$2" rel="noopener noreferrer">$1</a>',
    )
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])_([^_\n]+)_(?=[\s.,;:)]|$)/g, "$1<em>$2</em>");
}

export function renderMarkdown(markdown: string): string {
  const out: string[] = [];
  let listOpen = false;
  let paragraph: string[] = [];

  const closeParagraph = () => {
    if (paragraph.length) {
      out.push(`<p>${inline(paragraph.join(" "))}</p>`);
      paragraph = [];
    }
  };
  const closeList = () => {
    if (listOpen) {
      out.push("</ul>");
      listOpen = false;
    }
  };

  for (const rawLine of markdown.split("\n")) {
    const line = escapeHtml(rawLine.trimEnd());

    if (!line.trim()) {
      closeParagraph();
      closeList();
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      closeParagraph();
      closeList();
      const level = heading[1].length;
      out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      continue;
    }

    const bullet = line.match(/^[-*]\s+(.*)$/);
    if (bullet) {
      closeParagraph();
      if (!listOpen) {
        out.push("<ul>");
        listOpen = true;
      }
      out.push(`<li>${inline(bullet[1])}</li>`);
      continue;
    }

    closeList();
    // These documents are soft-wrapped at about 75 columns mid-sentence, so
    // consecutive lines are one paragraph, not one per line.
    paragraph.push(line.trim());
  }

  closeParagraph();
  closeList();
  return out.join("\n");
}
