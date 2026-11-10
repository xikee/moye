export function documentOutline(markdown) {
  const result = [];
  let fence = null;
  const lines = markdown.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      continue;
    }
    if (fence) continue;
    const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (heading) result.push({ level: heading[1].length, text: heading[2].replace(/[*_`~]/g, ''), line: i + 1 });
    else if (i > 0 && /^ {0,3}(?:=+|-+)\s*$/.test(line) && lines[i - 1].trim()) {
      result.push({ level: line.trim()[0] === '=' ? 1 : 2, text: lines[i - 1].trim(), line: i });
    }
  }
  return result;
}

export function documentStats(markdown) {
  const text = markdown.replace(/```[\s\S]*?```|~~~[\s\S]*?~~~/g, '').replace(/!\[[^\]]*\]\([^)]*\)/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[#*_`>~|\[\]]/g, '');
  const chinese = text.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/gu)?.length ?? 0;
  const words = text.replace(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/gu, ' ').match(/[\p{L}\p{N}]+/gu)?.length ?? 0;
  const count = chinese + words;
  return { count, lines: markdown.split('\n').length, minutes: Math.max(1, Math.ceil(count / 350)) };
}

export function safeFilename(name) {
  return name.replace(/[\x00-\x1f/\\:]/g, '-').trim() || '未命名';
}
