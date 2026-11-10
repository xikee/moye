import { defineConfig } from 'vite';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export default defineConfig({
  base: './',
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  build: {
    target: 'safari16',
    lib: {
      entry: fileURLToPath(new URL('./src/main.ts', import.meta.url)),
      name: 'MoYe',
      formats: ['iife'],
      fileName: () => 'editor.js',
      cssFileName: 'editor',
    },
    rollupOptions: {
      output: {
        manualChunks: undefined,
        inlineDynamicImports: true,
      },
    },
  },
  plugins: [{
    name: 'native-app-html',
    closeBundle() {
      const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8')
        .replace('<script type="module" src="/src/main.ts"></script>', '<link rel="stylesheet" href="./editor.css"><script defer src="./editor.js"></script>');
      writeFileSync(new URL('./dist/index.html', import.meta.url), html);
    },
  }],
});
