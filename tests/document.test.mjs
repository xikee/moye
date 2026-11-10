import test from 'node:test';
import assert from 'node:assert/strict';
import { documentOutline, documentStats, safeFilename } from '../src/document.mjs';

test('大纲忽略围栏内标题，支持 ATX 与 Setext 标题', () => {
  const markdown = '# 标题\n\n```md\n# 代码中的标题\n```\n\n## **子标题** ##\n\nSetext\n------\n\n~~~\n### 也是代码\n~~~';
  assert.deepEqual(documentOutline(markdown).map(({ level, text }) => ({ level, text })), [
    { level: 1, text: '标题' }, { level: 2, text: '子标题' }, { level: 2, text: 'Setext' },
  ]);
});

test('中文字符和西文单词分别计数，排除链接地址、图片和代码', () => {
  const markdown = '# 你好 world\n\n[链接](https://example.com) ![图片](image.png)\n\n```js\nconst hidden = 42;\n```';
  assert.equal(documentStats(markdown).count, 5);
  assert.equal(documentStats(markdown).lines, 7);
  assert.equal(documentStats(markdown).minutes, 1);
});

test('空文档的状态与保存文件名边界', () => {
  assert.deepEqual(documentStats(''), { count: 0, lines: 1, minutes: 1 });
  assert.equal(safeFilename('../a:b\\c'), '..-a-b-c');
  assert.equal(safeFilename('  '), '未命名');
});
