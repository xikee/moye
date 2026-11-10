import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const lock = JSON.parse(await readFile(join(root, 'package-lock.json'), 'utf8'));
const sections = ['墨页 MoYe — Third-party notices\n\nThe following open-source components are included in this application.'];
for (const [path, metadata] of Object.entries(lock.packages)) {
  if (!path || metadata.dev) continue;
  const location = join(root, path);
  const packageInfo = JSON.parse(await readFile(join(location, 'package.json'), 'utf8'));
  const files = (await readdir(location)).filter(name => /^(?:licen[sc]e|copying|notice)(?:\.|$)/i.test(name));
  sections.push(`\n${'='.repeat(72)}\n${packageInfo.name} ${packageInfo.version}\nLicense: ${typeof packageInfo.license === 'string' ? packageInfo.license : metadata.license || 'See package license'}\n`);
  for (const file of files) {
    try { sections.push(`${file}\n${await readFile(join(location, file), 'utf8')}`); } catch { /* 跳过同名目录。 */ }
  }
}
await writeFile(process.argv[2] || join(root, 'build', 'ThirdPartyNotices.txt'), sections.join('\n'));
