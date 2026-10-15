// Extracts Vikunja task references from memo text. Legacy implementation.

export function extractTaskRefs(text) {
  const marker = "vikunja-task:";
  const seen = new Set();
  const refs = [];
  let index = text.indexOf(marker);
  while (index !== -1) {
    let end = index + marker.length;
    while (end < text.length && text[end] >= "0" && text[end] <= "9") end++;
    const digits = text.slice(index + marker.length, end);
    const cancelled = index > 0 && text[index - 1] === "~";
    if (digits.length > 0 && !cancelled) {
      const id = Number(digits);
      if (id > 0 && !seen.has(id)) {
        seen.add(id);
        refs.push(id);
      }
    }
    index = text.indexOf(marker, end);
  }
  return refs;
}
