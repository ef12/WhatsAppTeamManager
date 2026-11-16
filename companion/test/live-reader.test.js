'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const readline = require('node:readline');

test('selected group messages and poll votes reach the app as live snapshots', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rkavic-reader-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const chrome = path.join(root, 'Google', 'Chrome', 'Application');
  fs.mkdirSync(chrome, { recursive: true });
  fs.writeFileSync(path.join(chrome, 'chrome.exe'), '');
  const data = path.join(root, 'RKAVICTeamManager', 'whatsapp-reader');
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(data, 'selected-group.json'), JSON.stringify({ id: 'test-group@g.us', name: 'Test team' }));
  const readerScript = process.env.RKAVIC_TEST_READER || path.join(__dirname, '../src/reader.js');
  const child = spawn(process.execPath, ['--require', path.join(__dirname, 'fake-whatsapp.js'), readerScript], {
    env: { ...process.env, LOCALAPPDATA: root, PROGRAMFILES: root, 'PROGRAMFILES(X86)': root, RKAVIC_APP_MODE: '1', RKAVIC_CAPTURE_CONSENT: 'YES' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const events = [];
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const lines = readline.createInterface({ input: child.stdout });
  lines.on('line', (line) => {
    if (!line.startsWith('RKAVIC_EVENT:')) return;
    const event = JSON.parse(line.slice('RKAVIC_EVENT:'.length));
    events.push(event);
    if (event.message?.id === 'poll-1' && event.message.votes?.some((vote) => vote.options.length === 0)) child.stdin.write('stop\n');
  });
  const timeout = setTimeout(() => child.kill(), 10000);
  const code = await new Promise((resolve) => child.on('exit', resolve));
  clearTimeout(timeout);
  assert.equal(code, 0, stderr);
  const snapshots = events.filter((event) => event.type === 'reader_message').map((event) => event.message);
  assert.ok(snapshots.some((item) => item.id === 'text-1' && item.sender === 'Revi' && item.text === 'Hello team'));
  assert.ok(snapshots.some((item) => item.id === 'own-message' && item.sender === 'you' && item.text === 'My message'));
  assert.ok(snapshots.some((item) => item.id === 'poll-1' && item.allowMultipleAnswers === true && item.options.includes('Yes') && item.votes.some((vote) => vote.voter === 'Revi' && vote.options.includes('Yes'))));
  assert.ok(snapshots.some((item) => item.id === 'poll-1' && item.votes.some((vote) => vote.options.includes('No'))));
  assert.ok(snapshots.some((item) => item.id === 'poll-1' && item.votes.some((vote) => vote.options.length === 0)));
  assert.ok(!snapshots.some((item) => item.id === 'other-message'));
});
