import type { Editor } from '@milkdown/kit/core';
import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { imageBlockSchema } from '@milkdown/kit/component/image-block';
import { DOMSerializer } from '@milkdown/kit/prose/model';

// Crepe 默认把 Markdown alt 用作缩放比例；文档语义与显示尺寸应独立保存。
export function configureMarkdown(editor: Editor) {
  editor.config(ctx => {
    ctx.update(imageBlockSchema.key, previous => ctx => {
      const schema = previous(ctx);
      return {
        ...schema,
        attrs: { ...schema.attrs, alt: { default: '', validate: 'string' } },
        parseDOM: [{
          tag: 'img[data-type="image-block"]',
          getAttrs: dom => {
            const image = dom as HTMLElement;
            const ratio = Number(image.getAttribute('ratio') ?? 1);
            return {
              src: image.getAttribute('src') || '',
              alt: image.getAttribute('alt') || '',
              caption: image.getAttribute('title') || image.getAttribute('caption') || '',
              ratio: Number.isFinite(ratio) && ratio > 0 ? ratio : 1,
            };
          },
        }],
        toDOM: node => ['img', {
          'data-type': 'image-block', src: node.attrs.src, alt: node.attrs.alt,
          title: node.attrs.caption, ratio: node.attrs.ratio,
        }],
        parseMarkdown: {
          match: node => node.type === 'image-block',
          runner: (state, node, type) => {
            state.addNode(type, {
              src: node.url as string, alt: (node.alt as string | null) ?? '',
              caption: (node.title as string | null) ?? '', ratio: 1,
            });
          },
        },
        toMarkdown: {
          match: node => node.type.name === 'image-block',
          runner: (state, node) => {
            state.openNode('paragraph');
            state.addNode('image', undefined, undefined, {
              url: node.attrs.src, alt: node.attrs.alt, title: node.attrs.caption || null,
            });
            state.closeNode();
          },
        },
      };
    });
  });
}

// 导出解析独立文档，不替换编辑器状态，避免影响光标、撤销和正文历史。
export function documentHTML(editor: Editor, markdown?: string): string {
  return editor.action(ctx => {
    const doc = markdown === undefined ? ctx.get(editorViewCtx).state.doc : ctx.get(parserCtx)(markdown);
    if (!doc) throw new Error('无法解析 Markdown');
    const container = document.createElement('div');
    container.append(DOMSerializer.fromSchema(doc.type.schema).serializeFragment(doc.content));
    return container.innerHTML;
  });
}
