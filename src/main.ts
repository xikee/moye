import { Crepe } from '@milkdown/crepe';
import { editorViewCtx } from '@milkdown/kit/core';
import { $prose, callCommand, getHTML, replaceAll } from '@milkdown/kit/utils';
import { toggleStrongCommand, toggleEmphasisCommand } from '@milkdown/kit/preset/commonmark';
import { toggleLinkCommand } from '@milkdown/kit/component/link-tooltip';
import { Plugin, PluginKey, TextSelection } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { EditorState } from '@codemirror/state';
import { EditorView, lineNumbers, keymap, highlightActiveLine } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { defaultHighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { SearchQuery, setSearchQuery, findNext, findPrevious, search } from '@codemirror/search';
import { createIcons, PanelLeft, FileText, CodeXml, Scan, SunMoon, Save, Ellipsis, SquarePen, FolderOpen, FolderPlus, CircleHelp, Search, ChevronUp, ChevronDown, X, FilePlus2, Files, FileCode2, FileDown, TextCursorInput, Keyboard } from 'lucide';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/classic.css';
import './style.css';
import { documentOutline, documentStats, safeFilename } from './document.mjs';
import { welcome } from './welcome';

type FileEntry = { name: string; path: string; relative?: string };
type DocumentPayload = { content: string; name: string; path?: string; dirty?: boolean; recovered?: boolean };
type NativePayload = { action: string; [key: string]: unknown };
declare global {
  interface Window {
    __moyeWelcome: string;
    webkit?: { messageHandlers: { native: { postMessage: (payload: NativePayload) => void } } };
    moye: {
      load: (payload: DocumentPayload) => void;
      state: (payload: { name: string; dirty: boolean; path?: string; status?: string }) => void;
      files: (files: FileEntry[], folder?: string) => void;
      command: (command: string) => void;
      toast: (message: string) => void;
      exportHTML: () => string;
      preparePrint: () => void;
      debugState: () => object;
    };
  }
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const native = (action: string, data: Record<string, unknown> = {}) => {
  if (window.webkit) window.webkit.messageHandlers.native.postMessage({ action, ...data });
  else browserAction(action, data);
};
let currentMarkdown = welcome;
let currentName = '开始书写.md';
let currentPath = '';
let sourceMode = false;
let suppressChanges = true;
let source: EditorView;
let outlineTimer: ReturnType<typeof setTimeout>;
let toastTimer: ReturnType<typeof setTimeout>;
let searchTerm = '';
let matches: { from: number; to: number }[] = [];
let selectedMatch = -1;
let zoom = Number(localStorage.getItem('moye-zoom') || 100);
let fileEntries: FileEntry[] = [];
let selectedHeading = -1;
let outlineObserver: IntersectionObserver | undefined;

createIcons({ icons: { PanelLeft, FileText, CodeXml, Scan, SunMoon, Save, Ellipsis, SquarePen, FolderOpen, FolderPlus, CircleHelp, Search, ChevronUp, ChevronDown, X, FilePlus2, Files, FileCode2, FileDown, TextCursorInput, Keyboard }, attrs: { 'stroke-width': 1.65 } });

const searchPlugin = $prose(() => new Plugin({
  key: new PluginKey('moyeSearch'),
  state: {
    init: () => DecorationSet.empty,
    apply(tr, old) {
      if (!tr.docChanged && !tr.getMeta('moyeSearch')) return old;
      matches = [];
      if (!searchTerm) return DecorationSet.empty;
      tr.doc.descendants((node, pos) => {
        if (!node.isTextblock) return;
        const text = node.textBetween(0, node.content.size, '', '\ufffc').toLocaleLowerCase();
        const needle = searchTerm.toLocaleLowerCase();
        for (let index = text.indexOf(needle); index >= 0; index = text.indexOf(needle, index + needle.length)) {
          matches.push({ from: pos + 1 + index, to: pos + 1 + index + needle.length });
        }
      });
      return DecorationSet.create(tr.doc, matches.map(match => Decoration.inline(match.from, match.to, { class: 'search-match' })));
    },
  },
  props: { decorations(state) { return this.getState(state); } },
}));

async function imageData(file: File): Promise<string> {
  if (file.size > 10 * 1024 * 1024) { toast('图片请控制在 10 MB 以内'); throw new Error('图片过大'); }
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

const crepe = new Crepe({
  root: $('rich-editor'),
  defaultValue: welcome,
  features: { [Crepe.Feature.TopBar]: false, [Crepe.Feature.AI]: false },
  featureConfigs: {
    [Crepe.Feature.Placeholder]: { text: '写下第一个字，让想法慢慢展开…', mode: 'doc' },
    [Crepe.Feature.ImageBlock]: {
      onUpload: imageData, inlineOnUpload: imageData, blockOnUpload: imageData,
      inlineUploadButton: '选择图片', blockUploadButton: '选择图片',
      inlineUploadPlaceholderText: '粘贴图片地址', blockUploadPlaceholderText: '粘贴图片地址，或选择本地图片',
      blockCaptionPlaceholderText: '添加图片说明', inlineConfirmButton: '插入', blockConfirmButton: '插入',
      proxyDomURL: (url) => {
        if (!url || /^(?:https?:|data:|blob:|moye:)/i.test(url)) return url;
        if (window.webkit) return `moye://document/${url.replace(/^\.\//, '')}`;
        return url;
      },
    },
    [Crepe.Feature.BlockEdit]: {
      textGroup: { label: '基础段落', text: { label: '正文' }, h1: { label: '一级标题' }, h2: { label: '二级标题' }, h3: { label: '三级标题' }, h4: { label: '四级标题' }, h5: { label: '五级标题' }, h6: { label: '六级标题' }, quote: { label: '引用' }, divider: { label: '分割线' } },
      listGroup: { label: '列表', bulletList: { label: '无序列表' }, orderedList: { label: '有序列表' }, taskList: { label: '任务清单' } },
      advancedGroup: { label: '更多内容', image: { label: '图片' }, codeBlock: { label: '代码块' }, table: { label: '表格' }, math: { label: '数学公式' } },
    },
  },
});
crepe.editor.use(searchPlugin);
// 直接观察 ProseMirror 文档变更，避免 Milkdown 的 200ms 防抖漏掉紧接着的保存。
crepe.editor.use($prose(() => new Plugin({
  view: () => ({
    update(view, previous) {
      if (!suppressChanges && !sourceMode && !previous.doc.eq(view.state.doc)) changed(crepe.getMarkdown());
    },
  }),
})));

function changed(markdown: string) {
  if (currentMarkdown === markdown) return;
  currentMarkdown = markdown;
  native('change', { content: markdown });
  if (!window.webkit) {
    localStorage.setItem('moye-browser-draft', markdown);
    setDocumentState({ name: currentName, dirty: true, status: '草稿已暂存' });
  }
  clearTimeout(outlineTimer);
  outlineTimer = setTimeout(refreshDocument, 160);
}

function refreshDocument() {
  const stats = documentStats(currentMarkdown);
  $('word-count').textContent = `${stats.count.toLocaleString()} 字`;
  $('line-count').textContent = `${stats.lines} 行`;
  $('reading-time').textContent = `${stats.minutes} 分钟阅读`;
  const outline = documentOutline(currentMarkdown);
  $('heading-count').textContent = String(outline.length);
  const nav = $('outline');
  nav.replaceChildren();
  if (!outline.length) {
    const empty = document.createElement('p');
    empty.className = 'sidebar-empty';
    empty.textContent = '标题会出现在这里。\n输入 # 和空格，写下第一个标题。';
    nav.append(empty);
  }
  outline.forEach((heading: { level: number; text: string; line: number }, index: number) => {
    const button = document.createElement('button');
    button.className = `outline-item level-${heading.level}`;
    button.style.setProperty('--level', String(Math.min(heading.level - 1, 3)));
    button.title = heading.text;
    const marker = document.createElement('span');
    marker.className = 'outline-marker';
    marker.textContent = String(heading.level).padStart(2, '0');
    const label = document.createElement('span');
    label.textContent = heading.text;
    button.append(marker, label);
    button.onclick = () => {
      if (sourceMode) {
        const line = source.state.doc.line(Math.min(heading.line, source.state.doc.lines));
        source.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: 'center' }) });
        source.focus();
      } else {
        const target = $('rich-editor').querySelectorAll('h1,h2,h3,h4,h5,h6')[index];
        target?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
      highlightHeading(index);
    };
    nav.append(button);
  });
  watchHeadings();
}

function highlightHeading(index: number) {
  selectedHeading = index;
  $('outline').querySelectorAll('button').forEach((button, i) => button.classList.toggle('active', i === index));
}

function watchHeadings() {
  outlineObserver?.disconnect();
  outlineObserver = new IntersectionObserver(entries => {
    const first = entries.filter(entry => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (first) highlightHeading(Number((first.target as HTMLElement).dataset.outlineIndex));
  }, { root: $('editor-scroll'), rootMargin: '-10% 0px -65% 0px' });
  $('rich-editor').querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((heading, index) => {
    (heading as HTMLElement).dataset.outlineIndex = String(index);
    outlineObserver?.observe(heading);
  });
  highlightHeading(Math.max(0, selectedHeading));
}

function syncRich() {
  const previous = suppressChanges;
  suppressChanges = true;
  crepe.editor.action(replaceAll(currentMarkdown));
  // 程序载入不应被视为用户编辑，也不应改变原始 Markdown。
  suppressChanges = previous;
}

function toggleSource() {
  const scroll = $('editor-scroll');
  const ratio = scroll.scrollTop / Math.max(1, scroll.scrollHeight - scroll.clientHeight);
  if (!sourceMode) {
    source.dispatch({ changes: { from: 0, to: source.state.doc.length, insert: currentMarkdown } });
  } else syncRich();
  sourceMode = !sourceMode;
  $('rich-editor').hidden = sourceMode;
  $('source-editor').hidden = !sourceMode;
  $('source-toggle').classList.toggle('active', sourceMode);
  $('source-toggle').setAttribute('aria-pressed', String(sourceMode));
  $('source-toggle').querySelector('span')!.textContent = sourceMode ? '正文' : '源码';
  $('mode-label').textContent = sourceMode ? 'SOURCE CODE' : 'MARKDOWN';
  $('status-mode').firstChild!.textContent = sourceMode ? '源码模式 ' : '即时渲染 ';
  document.body.classList.toggle('source-mode', sourceMode);
  requestAnimationFrame(() => {
    scroll.scrollTop = ratio * (scroll.scrollHeight - scroll.clientHeight);
    if (sourceMode) { source.requestMeasure(); source.focus(); }
    else crepe.editor.action(ctx => ctx.get(editorViewCtx).focus());
    refreshDocument();
    updateSearch();
  });
}

function setDocumentState(payload: { name: string; dirty: boolean; path?: string; status?: string }) {
  currentName = payload.name;
  if (payload.path !== undefined) currentPath = payload.path;
  $('document-name').textContent = currentName;
  $('document-name').title = currentPath || '尚未保存到文件';
  $('dirty-dot').hidden = !payload.dirty;
  $('save-status').textContent = payload.status || (payload.dirty ? '草稿已暂存' : currentPath ? '文件已保存' : '已就绪');
  document.title = `${currentName} — 墨页`;
  renderFiles();
}

function loadDocument(payload: DocumentPayload) {
  currentMarkdown = payload.content;
  currentPath = payload.path || '';
  suppressChanges = true;
  source.setState(makeSourceState(payload.content));
  crepe.editor.action(replaceAll(payload.content, true));
  $('editor-scroll').scrollTop = 0;
  selectedHeading = 0;
  setDocumentState({ ...payload, dirty: payload.dirty || false, status: payload.recovered ? '已恢复上次草稿' : undefined });
  suppressChanges = false;
  refreshDocument();
  updateSearch();
}

function renderFiles() {
  const list = $('files');
  list.replaceChildren();
  if (!fileEntries.length) {
    const empty = document.createElement('p');
    empty.className = 'sidebar-empty';
    empty.textContent = '打开一个文件或文件夹，\n让文字有个自己的位置。';
    list.append(empty);
  }
  for (const file of fileEntries) {
    const button = document.createElement('button');
    button.className = 'file-item';
    button.classList.toggle('active', file.path === currentPath);
    button.title = file.path;
    const icon = document.createElement('span');
    icon.textContent = 'md';
    icon.className = 'file-extension';
    const name = document.createElement('span');
    name.textContent = file.relative || file.name;
    button.append(icon, name);
    button.onclick = () => native('openPath', { path: file.path });
    list.append(button);
  }
}

function showFind() {
  $('find-bar').hidden = false;
  const input = $<HTMLInputElement>('find-input');
  input.focus();
  input.select();
}

function updateSearch() {
  searchTerm = $<HTMLInputElement>('find-input').value;
  if (sourceMode) {
    source.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: searchTerm, literal: true })) });
    const text = currentMarkdown.toLocaleLowerCase();
    const needle = searchTerm.toLocaleLowerCase();
    let count = 0;
    if (needle) for (let i = text.indexOf(needle); i >= 0; i = text.indexOf(needle, i + needle.length)) count++;
    $('find-result').textContent = needle ? `${count} 处` : '';
  } else {
    crepe.editor.action(ctx => { const view = ctx.get(editorViewCtx); view.dispatch(view.state.tr.setMeta('moyeSearch', true)); });
    $('find-result').textContent = searchTerm ? `${matches.length} 处` : '';
    selectedMatch = -1;
  }
}

function moveMatch(direction: number) {
  if (sourceMode) { (direction > 0 ? findNext : findPrevious)(source); return; }
  if (!matches.length) return;
  selectedMatch = (selectedMatch + direction + matches.length) % matches.length;
  const match = matches[selectedMatch];
  crepe.editor.action(ctx => {
    const view = ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, match.from, match.to)).scrollIntoView());
  });
  $('find-result').textContent = `${selectedMatch + 1} / ${matches.length}`;
}

function toast(message: string) {
  $('toast').textContent = message;
  $('toast').classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('toast').classList.remove('visible'), 2800);
}

function applyZoom(value: number) {
  zoom = Math.max(75, Math.min(150, value));
  document.documentElement.style.setProperty('--editor-font-size', `${17 * zoom / 100}px`);
  $('zoom-button').textContent = `${zoom}%`;
  localStorage.setItem('moye-zoom', String(zoom));
}

function setTheme(dark: boolean) {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  localStorage.setItem('moye-theme', dark ? 'dark' : 'light');
  native('theme', { dark });
}

function command(name: string) {
  switch (name) {
    case 'source': toggleSource(); break;
    case 'sidebar': document.body.classList.toggle('sidebar-hidden'); break;
    case 'focus': {
      const active = document.body.classList.toggle('focus-mode');
      $('focus-toggle').classList.toggle('active', active);
      $('focus-toggle').setAttribute('aria-pressed', String(active));
      toast(active ? '专注模式 · 按 ⌘⇧F 退出' : '已退出专注模式');
      break;
    }
    case 'typewriter': {
      const active = document.body.classList.toggle('typewriter-mode');
      $('typewriter-check').textContent = active ? '✓' : '';
      toast(active ? '已开启打字机模式' : '已关闭打字机模式');
      break;
    }
    case 'theme': setTheme(document.documentElement.dataset.theme !== 'dark'); break;
    case 'find': showFind(); break;
    case 'findNext': moveMatch(1); break;
    case 'zoomIn': applyZoom(zoom + 10); break;
    case 'zoomOut': applyZoom(zoom - 10); break;
    case 'zoomReset': applyZoom(100); break;
    case 'help': $<HTMLDialogElement>('help-dialog').showModal(); break;
    case 'bold': format('bold'); break;
    case 'italic': format('italic'); break;
    case 'link': format('link'); break;
  }
  $('more-menu').hidden = true;
  $('more-button').setAttribute('aria-expanded', 'false');
}

function format(kind: string) {
  if (sourceMode) {
    const range = source.state.selection.main;
    const text = source.state.sliceDoc(range.from, range.to) || '文字';
    const replacement = kind === 'bold' ? `**${text}**` : kind === 'italic' ? `*${text}*` : `[${text}](https://)`;
    source.dispatch({ changes: { from: range.from, to: range.to, insert: replacement }, selection: { anchor: range.from, head: range.from + replacement.length } });
    source.focus();
  } else if (kind === 'link') {
    crepe.editor.action(callCommand(toggleLinkCommand.key));
  } else {
    crepe.editor.action(callCommand(kind === 'bold' ? toggleStrongCommand.key : toggleEmphasisCommand.key));
    crepe.editor.action(ctx => ctx.get(editorViewCtx).focus());
  }
}

function makeSourceState(content: string) {
  return EditorState.create({ doc: content, extensions: [
    lineNumbers(), highlightActiveLine(), history(), markdown(), syntaxHighlighting(defaultHighlightStyle), search(),
    keymap.of([indentWithTab, ...defaultKeymap, ...historyKeymap]), EditorView.lineWrapping,
    EditorView.contentAttributes.of({ 'aria-label': 'Markdown 源码' }),
    EditorView.updateListener.of(update => { if (update.docChanged && sourceMode && !suppressChanges) changed(update.state.doc.toString()); }),
  ] });
}

function exportHTML() {
  if (sourceMode) syncRich();
  const fragment = document.createElement('template');
  fragment.innerHTML = crepe.editor.action(getHTML());
  fragment.content.querySelectorAll('li[data-item-type="task"]').forEach(item => {
    (item as HTMLElement).style.listStyle = 'none';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox'; checkbox.disabled = true;
    if (item.getAttribute('data-checked') === 'true') checkbox.setAttribute('checked', '');
    checkbox.style.marginRight = '8px';
    (item.querySelector('p') || item).prepend(checkbox);
  });
  const content = fragment.innerHTML;
  const title = currentName.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="generator" content="墨页"><title>${title}</title><style>body{max-width:760px;margin:64px auto;padding:0 32px;font:17px/1.9 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#2c302d}h1,h2,h3{line-height:1.4;margin-top:1.8em}h1{font-size:2em}a{color:#547663}blockquote{border-left:3px solid #8ca390;margin:24px 0;padding:4px 24px;background:#f5f7f4;color:#657067}pre{padding:22px;background:#f4f5f3;border-radius:8px;overflow:auto}code{font-family:Menlo,monospace;font-size:.85em}p code{background:#f0f2ee;padding:3px 5px;border-radius:4px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:10px 14px;text-align:left}th{background:#f5f6f3}img{max-width:100%}hr{border:0;border-top:1px solid #ddd;margin:36px 0}li{margin:5px 0}@media print{body{margin:0;max-width:none;font-size:11pt}pre,blockquote,tr{break-inside:avoid}h1,h2,h3{break-after:avoid}}</style></head><body>${content}</body></html>`;
}

function browserAction(action: string, data: Record<string, unknown>) {
  if (action === 'new') loadDocument({ content: '', name: '未命名.md' });
  if (action === 'save' || action === 'saveAs' || action === 'exportHTML') {
    const html = action === 'exportHTML';
    const blob = new Blob([html ? exportHTML() : currentMarkdown], { type: html ? 'text/html' : 'text/markdown' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a'); link.href = url; link.download = safeFilename(currentName.replace(/\.md$/, '')) + (html ? '.html' : '.md'); link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast(html ? '已导出 HTML' : '已下载 Markdown');
  }
  if (action === 'open') {
    const input = document.createElement('input'); input.type = 'file'; input.accept = '.md,.markdown,.txt';
    input.onchange = async () => { const file = input.files?.[0]; if (file) loadDocument({ content: await file.text(), name: file.name }); }; input.click();
  }
  if (action === 'exportPDF') { window.moye.preparePrint(); window.print(); }
  if (action === 'openFolder') toast('文件夹功能请在 macOS 桌面应用中使用');
  if (action === 'ready') {
    const draft = localStorage.getItem('moye-browser-draft');
    if (draft) loadDocument({ content: draft, name: '未命名.md', dirty: true, recovered: true });
  }
  void data;
}

const buttons: Record<string, () => void> = {
  'new-doc': () => native('new'), 'open-file': () => native('open'), 'open-folder': () => native('openFolder'),
  'save-file': () => native('save'), 'toggle-sidebar': () => command('sidebar'), 'source-toggle': toggleSource,
  'focus-toggle': () => command('focus'), 'theme-toggle': () => command('theme'), 'help': () => command('help'),
  'close-help': () => $<HTMLDialogElement>('help-dialog').close(), 'status-mode': toggleSource,
  'zoom-button': () => applyZoom(zoom >= 130 ? 90 : zoom + 10), 'find-prev': () => moveMatch(-1), 'find-next': () => moveMatch(1),
  'find-close': () => { $('find-bar').hidden = true; $<HTMLInputElement>('find-input').value = ''; updateSearch(); },
  'more-button': () => { $('more-menu').hidden = !$('more-menu').hidden; $('more-button').setAttribute('aria-expanded', String(!$('more-menu').hidden)); },
};
Object.entries(buttons).forEach(([id, handler]) => $(id).onclick = handler);
document.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach(button => button.onclick = () => {
  const isOutline = button.dataset.tab === 'outline';
  $('outline-panel').hidden = !isOutline; $('files-panel').hidden = isOutline;
  document.querySelectorAll<HTMLElement>('[data-tab]').forEach(tab => { tab.classList.toggle('active', tab === button); tab.setAttribute('aria-selected', String(tab === button)); });
});
document.querySelectorAll<HTMLButtonElement>('[data-action]').forEach(button => button.onclick = () => { native(button.dataset.action!); $('more-menu').hidden = true; });
document.querySelectorAll<HTMLButtonElement>('[data-command]').forEach(button => button.onclick = () => command(button.dataset.command!));
$<HTMLInputElement>('find-input').oninput = updateSearch;
$<HTMLInputElement>('find-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); moveMatch(event.shiftKey ? -1 : 1); } };
document.addEventListener('click', event => { if (!(event.target as HTMLElement).closest('#more-menu,#more-button')) { $('more-menu').hidden = true; $('more-button').setAttribute('aria-expanded', 'false'); } });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    $('more-menu').hidden = true;
    if (!$('find-bar').hidden) buttons['find-close']();
    else if (document.body.classList.contains('focus-mode')) command('focus');
  }
  if (!event.metaKey || event.isComposing) return;
  const key = event.key.toLowerCase();
  const actions: Record<string, () => void> = {
    n: () => native('new'), o: () => native('open'), s: () => native(event.shiftKey ? 'saveAs' : 'save'),
    '/': toggleSource, f: () => command(event.shiftKey ? 'focus' : 'find'),
    l: () => { if (event.shiftKey) command('sidebar'); }, '+': () => applyZoom(zoom + 10), '=': () => applyZoom(zoom + 10), '-': () => applyZoom(zoom - 10), '0': () => applyZoom(100),
  };
  if (actions[key] && (key !== 'l' || event.shiftKey)) { event.preventDefault(); actions[key](); }
});
document.addEventListener('selectionchange', () => {
  if (!document.body.classList.contains('typewriter-mode') || sourceMode) return;
  const selection = window.getSelection();
  if (!selection?.isCollapsed || !selection.rangeCount || !$('rich-editor').contains(selection.anchorNode)) return;
  const rect = selection.getRangeAt(0).getBoundingClientRect();
  const scrollRect = $('editor-scroll').getBoundingClientRect();
  if (rect.height) $('editor-scroll').scrollBy({ top: rect.top - scrollRect.top - scrollRect.height * .45, behavior: 'smooth' });
});

window.moye = {
  load: loadDocument, state: setDocumentState,
  files: (files, folder) => { fileEntries = files; $('folder-label').textContent = folder || '最近打开'; renderFiles(); },
  command, toast, exportHTML,
  preparePrint: () => { if (sourceMode) syncRich(); },
  debugState: () => ({ ready: true, sourceMode, markdown: currentMarkdown, name: currentName, path: currentPath, stats: documentStats(currentMarkdown), headings: documentOutline(currentMarkdown).length, editor: !!document.querySelector('.ProseMirror') }),
};
window.__moyeWelcome = welcome;

async function start() {
  await crepe.create();
  source = new EditorView({ state: makeSourceState(welcome), parent: $('source-editor') });
  document.documentElement.dataset.theme = localStorage.getItem('moye-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  applyZoom(zoom);
  refreshDocument();
  suppressChanges = false;
  native('ready', { welcome, dark: document.documentElement.dataset.theme === 'dark' });
}
start().catch(error => { console.error(error); native('error', { message: String(error) }); $('rich-editor').textContent = '编辑器启动失败，请关闭窗口后重试。'; });
