import { randomBytes } from 'node:crypto';
import { mkdir, writeFile, chmod } from 'node:fs/promises';
const directory = new URL('./secrets/', import.meta.url);
await mkdir(directory, { recursive: true, mode: 0o700 });
await chmod(directory, 0o700);
for (const [name, value] of [
  ['database_password', randomBytes(32).toString('hex')],
  ['room_token_secret', randomBytes(32).toString('hex')],
]) {
  try {
    await writeFile(new URL(name, directory), value + '\n', { flag: 'wx', mode: 0o444 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
}
console.log('Deployment secrets are ready. Existing files were preserved.');
